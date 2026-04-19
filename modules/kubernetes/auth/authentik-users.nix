{
  config,
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  secretsPath,
  ...
}:

# Declarative Authentik bootstrap users. Replaces the interactive step of the
# old wizard.sh: creates each user via the API, sets the password from agenix,
# and assigns group memberships. Idempotent: a content hash of the spec is
# stored in the marker, so re-running only happens when users/groups change.

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "authentik";
  markerFile = "/var/lib/authentik-bootstrap-users-done";

  users = serverConfig.authentik.bootstrapUsers or { };

  userList = lib.mapAttrsToList (username: cfg: {
    inherit username;
    email = cfg.email;
    name = cfg.name or username;
    groups = cfg.groups or [ ];
    passwordSecret = cfg.passwordSecret;
  }) users;

  configHash = builtins.hashString "sha256" (builtins.toJSON userList);

  renderUser = u: ''

    echo ""
    echo "=== ${u.username} ==="
    USER_PK=$($CURL -s "$API/core/users/?username=${u.username}" -H "$AUTH" | $JQ -r '.results[0].pk // empty')

    if [ -z "$USER_PK" ]; then
      BODY=$($JQ -n \
        --arg u "${u.username}" \
        --arg n "${u.name}" \
        --arg e "${u.email}" \
        '{username: $u, name: $n, email: $e, is_active: true}')
      USER_PK=$($CURL -s -X POST "$API/core/users/" -H "$AUTH" -H "Content-Type: application/json" -d "$BODY" | $JQ -r '.pk // empty')
      if [ -z "$USER_PK" ]; then
        echo "ERROR creating ${u.username}"
        exit 1
      fi
      echo "Created ${u.username} (pk=$USER_PK)"

      PASSWORD=$(cat "${config.age.secrets."authentik-user-${u.username}-password".path}")
      PW_BODY=$($JQ -n --arg p "$PASSWORD" '{password: $p}')
      $CURL -s -X POST "$API/core/users/$USER_PK/set_password/" -H "$AUTH" -H "Content-Type: application/json" -d "$PW_BODY" > /dev/null
      echo "Password set"
    else
      echo "${u.username} already exists (pk=$USER_PK)"
    fi

    ${lib.concatMapStringsSep "\n" (g: ''
      GRP_PK=$($CURL -s "$API/core/groups/?name=${g}" -H "$AUTH" | $JQ -r '.results[0].pk // empty')
      if [ -z "$GRP_PK" ]; then
        echo "  WARN group '${g}' not found, skipping"
      else
        $CURL -s -X POST "$API/core/groups/$GRP_PK/add_user/" -H "$AUTH" -H "Content-Type: application/json" -d "{\"pk\": $USER_PK}" > /dev/null
        echo "  -> added to ${g}"
      fi
    '') u.groups}
  '';
in
{
  age.secrets = lib.mapAttrs' (
    username: cfg:
    lib.nameValuePair "authentik-user-${username}-password" {
      file = "${secretsPath}/${cfg.passwordSecret}.age";
    }
  ) users;

  systemd.services.authentik-bootstrap-users-setup = {
    description = "Create bootstrap users in Authentik";
    after = [
      "authentik-sso-setup.service"
      "k3s-core.target"
    ];
    requires = [ "k3s-core.target" ];
    wants = [ "authentik-sso-setup.service" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "authentik-bootstrap-users-setup" ''
        ${k8s.libShSource}

        CONFIG_HASH="${configHash}"
        setup_preamble_hash "${markerFile}" "Authentik bootstrap users" "$CONFIG_HASH"
        wait_for_k3s

        API_TOKEN=$(get_secret_value "${ns}" "authentik-api-token" "TOKEN")
        if [ -z "$API_TOKEN" ]; then
          echo "ERROR: authentik-api-token secret missing (is authentik-sso-setup done?)"
          exit 1
        fi
        AUTH="Authorization: Bearer $API_TOKEN"

        pkill -f 'port-forward.*19001' 2>/dev/null || true
        sleep 3
        $KUBECTL port-forward -n ${ns} svc/authentik-server 19001:80 &
        PF_PID=$!
        trap "kill $PF_PID 2>/dev/null || true" EXIT
        sleep 5

        API="http://localhost:19001/api/v3"

        for i in $(seq 1 30); do
          if $CURL -sf "http://localhost:19001/-/health/live/" &>/dev/null; then break; fi
          echo "Waiting for Authentik API... ($i/30)"
          sleep 3
        done

        ${lib.concatMapStrings renderUser userList}

        print_success "Authentik bootstrap users" \
          "Users: ${lib.concatStringsSep ", " (map (u: u.username) userList)}"

        create_marker "${markerFile}" "$CONFIG_HASH"
      '';
    };
  };
}
