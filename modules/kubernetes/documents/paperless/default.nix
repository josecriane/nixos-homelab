{
  k8s,
  config,
  lib,
  serverConfig,
  ...
}:

let
  ns = "extra";

  cloudNas = lib.findFirst (
    cfg: (cfg.enabled or false) && (cfg.cloudPaths or { }) ? "paperless"
  ) null (lib.attrValues config.homelab.nas);

  cloudHostPath =
    if cloudNas != null then "/mnt/${cloudNas.hostname}/${cloudNas.cloudPaths.paperless}" else null;

  documentsPvc = k8s.applyManifestsScript {
    name = "paperless-documents";
    manifests = [ ./paperless-documents-pvc.yaml ];
    substitutions = {
      NAMESPACE = ns;
    };
  };

  preScript = ''
    if [ -z "${toString cloudHostPath}" ]; then
      echo "ERROR: no cloudPaths.paperless configured on any enabled NAS"
      exit 1
    fi

    for dir in media consume export; do
      mkdir -p "${toString cloudHostPath}/$dir"
      chown ${toString serverConfig.puid}:${toString serverConfig.pgid} "${toString cloudHostPath}/$dir" 2>/dev/null || true
      chmod 775 "${toString cloudHostPath}/$dir" 2>/dev/null || true
    done

    if ! $KUBECTL get pv paperless-data-pv >/dev/null 2>&1; then
      echo "ERROR: PV paperless-data-pv missing, nfs-storage-cloud-setup should have created it"
      exit 1
    fi

    if [ "$($KUBECTL get pvc paperless-documents -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null)" != "Bound" ]; then
      ${documentsPvc}
    fi

    if ! $KUBECTL get pvc paperless-data -n ${ns} >/dev/null 2>&1; then
      create_pvc "paperless-data" "${ns}" "5Gi"
    fi

    CLIENT_ID=$(get_secret_value "${ns}" "authentik-sso-credentials" "PAPERLESS_CLIENT_ID")
    CLIENT_SECRET=$(get_secret_value "${ns}" "authentik-sso-credentials" "PAPERLESS_CLIENT_SECRET")
    AUTHENTIK_URL=$(get_secret_value "${ns}" "authentik-sso-credentials" "AUTHENTIK_URL")

    if [ -z "$CLIENT_SECRET" ] || [ -z "$AUTHENTIK_URL" ]; then
      echo "ERROR: authentik-sso-credentials in ${ns} has no Paperless client"
      exit 1
    fi

    SECRET_KEY=$(get_secret_value "${ns}" "paperless-oidc" "PAPERLESS_SECRET_KEY")
    [ -z "$SECRET_KEY" ] && SECRET_KEY=$($OPENSSL rand -hex 32)

    ADMIN_PASSWORD=$(get_secret_value "${ns}" "paperless-oidc" "PAPERLESS_ADMIN_PASSWORD")
    [ -z "$ADMIN_PASSWORD" ] && ADMIN_PASSWORD=$($OPENSSL rand -hex 16)

    PROVIDERS=$($JQ -n \
      --arg cid "$CLIENT_ID" \
      --arg secret "$CLIENT_SECRET" \
      --arg url "$AUTHENTIK_URL/application/o/paperless/.well-known/openid-configuration" \
      '{openid_connect: {SCOPE: ["openid", "profile", "email"], APPS: [{provider_id: "authentik", name: "Authentik", client_id: $cid, secret: $secret, settings: {server_url: $url}}]}}')

    APPLY_OUTPUT=$($KUBECTL -n ${ns} create secret generic paperless-oidc \
      --from-literal=PAPERLESS_SECRET_KEY="$SECRET_KEY" \
      --from-literal=PAPERLESS_ADMIN_USER="admin" \
      --from-literal=PAPERLESS_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
      --from-literal=PAPERLESS_SOCIALACCOUNT_PROVIDERS="$PROVIDERS" \
      --dry-run=client -o yaml | $KUBECTL apply -f -)
    $KUBECTL -n ${ns} label secret paperless-oidc k8s/credential=true --overwrite >/dev/null

    echo "$APPLY_OUTPUT"

    PAPERLESS_SECRET_CHANGED=0
    case "$APPLY_OUTPUT" in
      *configured*) PAPERLESS_SECRET_CHANGED=1 ;;
    esac
  '';

  extraScript = ''
    if [ "$PAPERLESS_SECRET_CHANGED" = "1" ]; then
      echo "paperless-oidc changed, restarting the deployment so it picks the new values up..."
      $KUBECTL -n ${ns} rollout restart deploy/paperless
      $KUBECTL -n ${ns} rollout status deploy/paperless --timeout=300s
    fi
  '';

  release = k8s.createHelmRelease {
    name = "paperless";
    namespace = ns;
    tier = "extras";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    waitFor = "paperless";
    timeout = "10m";
    pssLevel = "privileged";
    inherit preScript extraScript;
    ingress = {
      host = "paperless";
      service = "paperless";
      port = 8000;
    };
  };
in
lib.recursiveUpdate release {
  sso.oidcApps = [
    {
      name = "Paperless";
      slug = "paperless";
      host = "paperless";
      namespace = ns;
      redirectPaths = [ "/accounts/oidc/authentik/login/callback/" ];
    }
  ];

  systemd.services.paperless-setup = {
    after = release.systemd.services.paperless-setup.after ++ [
      "authentik-sso-setup.service"
      "nfs-storage-cloud-setup.service"
    ];
    wants = [
      "authentik-sso-setup.service"
      "nfs-storage-cloud-setup.service"
    ];
  };
}
