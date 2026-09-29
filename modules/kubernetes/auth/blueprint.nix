# Declarative authentik objects, delivered as a blueprint.
#
# authentik applies blueprints itself and re-applies them every 60 minutes, so
# the objects converge without anyone running a deploy. The blueprint lives in
# the database (`BlueprintInstance.content`), which means no chart values and no
# authentik restart are needed to change it.
#
# Two properties matter here and both were verified against a live install:
#
#   - Entries adopt objects that already exist. The importer looks them up by
#     `identifiers`, and on a hit it updates that row in place, same pk, with
#     `partial=True`, so relations and unmentioned fields survive. Objects the
#     old shell scripts created are therefore taken over, not duplicated.
#   - Writing the blueprint through the API validates it first: the serializer
#     runs the whole import inside a transaction that always rolls back, and
#     refuses the write if anything fails. A broken blueprint never reaches the
#     objects.
#
# The outpost entry lists every proxy provider, so removing an app from the
# lists below also removes it from the outpost. The shell version only ever
# added, which is how the Stirling PDF provider stayed behind after its app was
# gone.
{
  config,
  k8s,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  ns = "authentik";
  markerFile = "/var/lib/authentik-blueprint-setup-done";
  blueprintName = "homelab - forward auth, groups and outpost";

  h = k8s.hostname;

  authFlow = "default-provider-authorization-implicit-consent";
  invalidationFlow = "default-provider-invalidation-flow";
  signingCert = "authentik Self-signed Certificate";
  outpostName = "authentik Embedded Outpost";

  groups = [
    {
      name = "admins";
      superuser = true;
    }
    { name = "media-admins"; }
    { name = "media-users"; }
    { name = "family"; }
    { name = "monitoring"; }
  ];

  # Forward-auth apps this repo installs. The arr stack skips /api so external
  # clients keep working with their API keys.
  arrSkip = "^/api.*";

  builtinApps = [
    {
      name = "Sonarr";
      slug = "sonarr";
      host = "sonarr";
      skipPath = arrSkip;
    }
    {
      name = "Sonarr ES";
      slug = "sonarr-es";
      host = "sonarr-es";
      skipPath = arrSkip;
    }
    {
      name = "Radarr";
      slug = "radarr";
      host = "radarr";
      skipPath = arrSkip;
    }
    {
      name = "Radarr ES";
      slug = "radarr-es";
      host = "radarr-es";
      skipPath = arrSkip;
    }
    {
      name = "Prowlarr";
      slug = "prowlarr";
      host = "prowlarr";
      skipPath = arrSkip;
    }
    {
      name = "qBittorrent";
      slug = "qbittorrent";
      host = "qbit";
      skipPath = arrSkip;
    }
    {
      name = "Bazarr";
      slug = "bazarr";
      host = "bazarr";
      skipPath = arrSkip;
    }
    {
      name = "Lidarr";
      slug = "lidarr";
      host = "lidarr";
      skipPath = arrSkip;
    }
    {
      name = "Bookshelf";
      slug = "bookshelf";
      host = "books";
      skipPath = arrSkip;
    }
    {
      name = "Prometheus";
      slug = "prometheus";
      host = "prometheus";
    }
    {
      name = "Alertmanager";
      slug = "alertmanager";
      host = "alertmanager";
    }
    {
      name = "Traefik";
      slug = "traefik";
      host = "traefik";
    }
    {
      name = "Longhorn";
      slug = "longhorn";
      host = "longhorn";
    }
  ];

  extraApps = serverConfig.authentik.forwardAuthApps or [ ];

  rawNas = config.homelab.nas;
  nasConfig =
    if rawNas ? ip then
      {
        nas1 = rawNas // {
          hostname = "nas";
        };
      }
    else
      rawNas;
  enabledNas = lib.filterAttrs (_: cfg: cfg.enabled or false) nasConfig;

  nasLabel =
    nasName:
    let
      num = lib.removePrefix "nas" nasName;
    in
    if num != nasName then "NAS ${num}" else nasName;

  nasApps = lib.flatten (
    lib.mapAttrsToList (
      nasName: nasCfg:
      let
        hostName = nasCfg.hostname or "nas";
        suffix = lib.removePrefix "nas" hostName;
      in
      [
        {
          name = "${nasLabel nasName} Cockpit";
          slug = "${nasName}-cockpit";
          hostFqdn = "https://${h hostName}";
          skipPath = arrSkip;
          providerSuffix = "Provider";
          appSuffix = "";
          slugSuffix = "";
        }
        {
          name = "${nasLabel nasName} Files";
          slug = "${nasName}-files";
          hostFqdn = "https://${h "files${suffix}"}";
          skipPath = arrSkip;
          providerSuffix = "Provider";
          appSuffix = "";
          slugSuffix = "";
        }
      ]
    ) enabledNas
  );

  # Normalise both shapes into one list the renderer walks.
  normalise = app: {
    inherit (app) name slug;
    providerName = "${app.name} ${app.providerSuffix or "Forward Auth"}";
    appName = "${app.name}${app.appSuffix or " (ForwardAuth)"}";
    appSlug = "${app.slug}${app.slugSuffix or "-fwd"}";
    externalHost = app.hostFqdn or "https://${h app.host}";
    skipPath = app.skipPath or "";
    entryId = "provider-${app.slug}";
  };

  proxyApps = map normalise (builtinApps ++ extraApps ++ nasApps);

  quote = s: ''"${s}"'';

  # Entries are built as lists of lines and indented once, because Nix strips
  # the common indentation of a '' string and that silently flattens any
  # conditional fragment nested inside one.
  pad = n: lines: map (l: "${lib.strings.replicate n " "}${l}") lines;

  mkEntry =
    {
      model,
      identifiers,
      attrs,
    }:
    [ "- model: ${model}" ]
    ++ (lib.optional (identifiers ? id) "  id: ${identifiers.id}")
    ++ [ "  identifiers:" ]
    ++ pad 4 identifiers.lines
    ++ [ "  attrs:" ]
    ++ pad 4 attrs;

  groupLines = lib.concatMap (
    group:
    mkEntry {
      model = "authentik_core.group";
      identifiers.lines = [ "name: ${quote group.name}" ];
      attrs = [
        "name: ${quote group.name}"
        "is_superuser: ${if group.superuser or false then "true" else "false"}"
      ];
    }
  ) groups;

  proxyLines = lib.concatMap (
    app:
    mkEntry {
      model = "authentik_providers_proxy.proxyprovider";
      identifiers = {
        id = app.entryId;
        lines = [ "name: ${quote app.providerName}" ];
      };
      attrs = [
        "name: ${quote app.providerName}"
        "mode: forward_single"
        "external_host: ${quote app.externalHost}"
        ''access_token_validity: "hours=1"''
        "authorization_flow: !Find [authentik_flows.flow, [slug, ${authFlow}]]"
        "invalidation_flow: !Find [authentik_flows.flow, [slug, ${invalidationFlow}]]"
        "certificate: !Find [authentik_crypto.certificatekeypair, [name, ${quote signingCert}]]"
      ]
      ++ lib.optional (app.skipPath != "") "skip_path_regex: ${quote app.skipPath}";
    }
    ++ mkEntry {
      model = "authentik_core.application";
      identifiers.lines = [ "slug: ${quote app.appSlug}" ];
      attrs = [
        "name: ${quote app.appName}"
        "slug: ${quote app.appSlug}"
        "provider: !KeyOf ${app.entryId}"
        "meta_launch_url: ${quote app.externalHost}"
      ];
    }
  ) proxyApps;

  outpostLines = mkEntry {
    model = "authentik_outposts.outpost";
    identifiers.lines = [ "name: ${quote outpostName}" ];
    attrs = [
      "name: ${quote outpostName}"
      "type: proxy"
      "config:"
      "  authentik_host: ${quote "https://${h "auth"}/"}"
      "providers:"
    ]
    ++ map (app: "  - !KeyOf ${app.entryId}") proxyApps;
  };

  blueprintYaml = lib.concatStringsSep "\n" (
    [
      "version: 1"
      "metadata:"
      "  name: ${quote blueprintName}"
      "entries:"
    ]
    ++ pad 2 (groupLines ++ proxyLines ++ outpostLines)
    ++ [ "" ]
  );

  blueprintFile = pkgs.writeText "authentik-blueprint.yaml" blueprintYaml;
in
{
  systemd.services.authentik-blueprint-setup = {
    description = "Push the authentik blueprint and apply it";
    after = [
      "k3s-core.target"
      "authentik-setup.service"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-core.target" ];
    wants = [
      "authentik-setup.service"
      "authentik-sso-setup.service"
    ];
    wantedBy = [ "k3s-apps.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "authentik-blueprint-setup" ''
        ${k8s.libShSource}

        setup_preamble_hash "${markerFile}" "Authentik blueprint" "${blueprintFile}"
        wait_for_k3s

        TOKEN=$(get_secret_value "${ns}" "authentik-api-token" "TOKEN")
        if [ -z "$TOKEN" ]; then
          echo "ERROR: no authentik API token in ${ns}/authentik-api-token"
          echo "  authentik-sso-setup creates it; run that first"
          exit 1
        fi

        API="http://localhost:19000/api/v3"
        PF_PID=""
        cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
        trap cleanup EXIT

        $KUBECTL -n ${ns} port-forward svc/authentik-server 19000:80 >/dev/null 2>&1 &
        PF_PID=$!
        for _ in $(seq 1 30); do
          ${pkgs.curl}/bin/curl -sf "http://localhost:19000/-/health/live/" >/dev/null 2>&1 && break
          sleep 2
        done
        if ! ${pkgs.curl}/bin/curl -sf "http://localhost:19000/-/health/live/" >/dev/null 2>&1; then
          echo "ERROR: authentik API not reachable"
          exit 1
        fi

        AUTH="Authorization: Bearer $TOKEN"
        CONTENT=$(${pkgs.jq}/bin/jq -Rs . < ${blueprintFile})

        # The write itself validates: the serializer runs the import inside a
        # transaction that rolls back, and refuses the write if it fails.
        # Filter on the exact name: the list is paginated and ordered by name, so
        # walking .results only finds the blueprint while it happens to land on
        # the first page.
        PK=$(${pkgs.curl}/bin/curl -s -G "$API/managed/blueprints/" \
          --data-urlencode "name=${blueprintName}" -H "$AUTH" \
          | ${pkgs.jq}/bin/jq -r --arg n "${blueprintName}" \
              '.results[] | select(.name == $n) | .pk // empty')

        if [ -z "$PK" ]; then
          echo "Creating the blueprint..."
          RESPONSE=$(${pkgs.curl}/bin/curl -s -X POST "$API/managed/blueprints/" \
            -H "$AUTH" -H "Content-Type: application/json" \
            -d "{\"name\": \"${blueprintName}\", \"path\": \"\", \"enabled\": true, \"content\": $CONTENT}")
          PK=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.pk // empty')
          if [ -z "$PK" ]; then
            echo "ERROR: authentik refused the blueprint:"
            echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.. | strings' | head -20
            exit 1
          fi
        else
          echo "Updating the blueprint ($PK)..."
          RESPONSE=$(${pkgs.curl}/bin/curl -s -X PATCH "$API/managed/blueprints/$PK/" \
            -H "$AUTH" -H "Content-Type: application/json" \
            -d "{\"content\": $CONTENT, \"enabled\": true}")
          if [ "$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.pk // empty')" != "$PK" ]; then
            echo "ERROR: authentik refused the blueprint:"
            echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.. | strings' | head -20
            exit 1
          fi
        fi

        # The apply endpoint queues a worker task and answers with the state as
        # it was, so the status has to be polled. It lands as `unknown` until the
        # worker finishes.
        echo "Applying..."
        ${pkgs.curl}/bin/curl -sf -X POST "$API/managed/blueprints/$PK/apply/" -H "$AUTH" >/dev/null

        STATUS="unknown"
        for _ in $(seq 1 45); do
          STATUS=$(${pkgs.curl}/bin/curl -s "$API/managed/blueprints/$PK/" -H "$AUTH" \
            | ${pkgs.jq}/bin/jq -r '.status // "unknown"')
          case "$STATUS" in
            successful | error) break ;;
          esac
          sleep 2
        done

        echo "Blueprint status: $STATUS"
        if [ "$STATUS" != "successful" ]; then
          echo "ERROR: the blueprint did not apply cleanly (status: $STATUS)"
          echo "  the worker log has the detail: kubectl -n ${ns} logs deploy/authentik-worker"
          exit 1
        fi

        create_marker "${markerFile}" "${blueprintFile}"
        print_success "Authentik blueprint" \
          "${toString (builtins.length proxyApps)} proxy providers and their applications" \
          "${toString (builtins.length groups)} groups" \
          "Outpost provider list is now exact: removals take effect"
      '';
    };
  };
}
