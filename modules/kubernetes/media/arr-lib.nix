{ lib, ... }:

let
  ns = "media";

  apps = {
    sonarr = {
      port = 8989;
      api = "v3";
      label = "Sonarr";
    };
    sonarr-es = {
      port = 8989;
      api = "v3";
      label = "Sonarr ES";
    };
    radarr = {
      port = 7878;
      api = "v3";
      label = "Radarr";
    };
    radarr-es = {
      port = 7878;
      api = "v3";
      label = "Radarr ES";
    };
    lidarr = {
      port = 8686;
      api = "v1";
      label = "Lidarr";
    };
    bookshelf = {
      port = 8787;
      api = "v1";
      label = "Bookshelf";
    };
    prowlarr = {
      port = 9696;
      api = "v1";
      label = "Prowlarr";
    };
  };

  appNames = builtins.attrNames apps;

  baseCase = lib.concatMapStringsSep "\n" (
    name:
    let
      app = apps.${name};
    in
    "    ${name}) echo \"http://localhost:${toString app.port}/api/${app.api}\" ;;"
  ) appNames;

  labelCase = lib.concatMapStringsSep "\n" (
    name: "    ${name}) echo ${lib.escapeShellArg apps.${name}.label} ;;"
  ) appNames;

  readyHelper = ''
    arr_ready() {
      local app="$1"
      if [ "$($KUBECTL get deploy -n ${ns} "$app" -o jsonpath='{.spec.replicas}' 2>/dev/null)" = "0" ]; then
        return 1
      fi
      for _ in $(seq 1 30); do
        if $KUBECTL get pods -n ${ns} -l app="$app" \
          -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
          return 0
        fi
        if $KUBECTL get pods -n ${ns} -l app.kubernetes.io/name="$app" \
          -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
          return 0
        fi
        sleep 5
      done
      return 1
    }
  '';

  helpers = ''
    declare -A ARR_KEY_CACHE

    arr_base() {
      case "$1" in
    ${baseCase}
        *) echo "" ;;
      esac
    }

    arr_label() {
      case "$1" in
    ${labelCase}
        *) echo "$1" ;;
      esac
    }

    arr_ready() {
      local app="$1"
      if [ "$($KUBECTL get deploy -n ${ns} "$app" -o jsonpath='{.spec.replicas}' 2>/dev/null)" = "0" ]; then
        return 1
      fi
      for _ in $(seq 1 30); do
        if $KUBECTL get pods -n ${ns} -l app="$app" \
          -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
          return 0
        fi
        if $KUBECTL get pods -n ${ns} -l app.kubernetes.io/name="$app" \
          -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
          return 0
        fi
        sleep 5
      done
      return 1
    }

    arr_stable_key() {
      $KUBECTL get secret "$1-api-key" -n ${ns} -o jsonpath='{.data.api-key}' 2>/dev/null \
        | base64 -d 2>/dev/null || echo ""
    }

    arr_key() {
      local app="$1"
      if [ -z "''${ARR_KEY_CACHE[$app]:-}" ]; then
        ARR_KEY_CACHE[$app]=$(get_secret_value ${ns} "$app-credentials" API_KEY)
        if [ -z "''${ARR_KEY_CACHE[$app]}" ]; then
          ARR_KEY_CACHE[$app]=$(arr_stable_key "$app")
        fi
      fi
      printf '%s' "''${ARR_KEY_CACHE[$app]}"
    }

    arr_request() {
      local app="$1" method="$2" path="$3" body="''${4:-}"
      local base key
      base=$(arr_base "$app")
      key=$(arr_key "$app")
      if [ -z "$base" ] || [ -z "$key" ]; then
        return 1
      fi
      if [ -n "$body" ]; then
        $KUBECTL exec -n ${ns} deploy/"$app" -- curl -s -X "$method" "$base/$path" \
          -H "X-Api-Key: $key" -H "Content-Type: application/json" -d "$body" 2>&1
      else
        $KUBECTL exec -n ${ns} deploy/"$app" -- curl -s -X "$method" "$base/$path" \
          -H "X-Api-Key: $key" 2>/dev/null
      fi
    }

    arr_get() { arr_request "$1" GET "$2"; }
    arr_post() { arr_request "$1" POST "$2" "$3"; }
    arr_put() { arr_request "$1" PUT "$2" "$3"; }

    arr_usable() {
      local app="$1" label
      label=$(arr_label "$app")
      if ! arr_ready "$app"; then
        echo "  $label: not running, skipped"
        return 1
      fi
      if [ -z "$(arr_key "$app")" ]; then
        echo "  $label: no API key, skipped"
        return 1
      fi
      return 0
    }

    arr_error_of() {
      echo "$1" | $JQ -r '
        if type == "array" then (.[0].errorMessage // .[0].message // "unknown error")
        else (.message // .error // "unknown error") end
      ' 2>/dev/null || echo "unknown error"
    }


    arr_api_ready() {
      local app="$1"
      for _ in $(seq 1 12); do
        if arr_get "$app" system/status | $JQ -e .version >/dev/null 2>&1; then
          return 0
        fi
        sleep 5
      done
      return 1
    }

    arr_ensure() {
      local app="$1" path="$2" payload="$3" match="$4" what="$5"
      local label existing result
      label=$(arr_label "$app")
      arr_usable "$app" || return 0
      existing=$(arr_get "$app" "$path" | $JQ "$match" 2>/dev/null || echo "")
      if [ -n "$existing" ]; then
        echo "  $label: $what already configured"
        return 0
      fi
      result=$(arr_post "$app" "$path" "$payload")
      if echo "$result" | $JQ -e '.id' >/dev/null 2>&1; then
        echo "  $label: $what configured"
      else
        echo "  $label: $what error - $(arr_error_of "$result")"
      fi
    }


    arr_patch() {
      local app="$1" path="$2" filter="$3" what="$4" write_path="''${5:-$2}"
      local label current updated
      label=$(arr_label "$app")
      arr_usable "$app" || return 0
      current=$(arr_get "$app" "$path")
      if [ -z "$current" ]; then
        echo "  $label: could not read $what"
        return 0
      fi
      updated=$(echo "$current" | $JQ "$filter")
      if [ -z "$updated" ]; then
        echo "  $label: $what filter produced nothing, skipped"
        return 0
      fi
      arr_put "$app" "$write_path" "$updated" >/dev/null 2>&1
      echo "  $label: $what configured"
    }

    arr_enforce() {
      local app="$1" path="$2" payload="$3" what="$4"
      local label result
      label=$(arr_label "$app")
      arr_usable "$app" || return 0
      result=$(arr_put "$app" "$path" "$payload")
      if echo "$result" | $JQ -e '.id // .enable // .name' >/dev/null 2>&1; then
        echo "  $label: $what enforced"
      else
        echo "  $label: $what error - $(arr_error_of "$result")"
      fi
    }
  '';
in
{
  inherit
    readyHelper
    ns
    apps
    appNames
    helpers
    ;

  baseUrl = name: "http://localhost:${toString apps.${name}.port}/api/${apps.${name}.api}";
  labelOf = name: apps.${name}.label;
}
