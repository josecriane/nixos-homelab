{
  k8s,
  lib,
  ...
}:

let
  ns = "extra";

  preScript = ''
    if ! $KUBECTL get pvc stirling-pdf-configs -n ${ns} >/dev/null 2>&1; then
      create_pvc "stirling-pdf-configs" "${ns}" "1Gi"
    fi

    CLIENT_ID=$(get_secret_value "${ns}" "authentik-sso-credentials" "STIRLING_PDF_CLIENT_ID")
    CLIENT_SECRET=$(get_secret_value "${ns}" "authentik-sso-credentials" "STIRLING_PDF_CLIENT_SECRET")

    if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
      echo "ERROR: authentik-sso-credentials in ${ns} has no Stirling PDF client"
      exit 1
    fi

    INITIAL_PASSWORD=$(get_secret_value "${ns}" "stirling-pdf-auth" "SECURITY_INITIALLOGIN_PASSWORD")
    [ -z "$INITIAL_PASSWORD" ] && INITIAL_PASSWORD=$($OPENSSL rand -hex 16)

    APPLY_OUTPUT=$($KUBECTL -n ${ns} create secret generic stirling-pdf-auth \
      --from-literal=SECURITY_OAUTH2_CLIENTID="$CLIENT_ID" \
      --from-literal=SECURITY_OAUTH2_CLIENTSECRET="$CLIENT_SECRET" \
      --from-literal=SECURITY_INITIALLOGIN_USERNAME="admin" \
      --from-literal=SECURITY_INITIALLOGIN_PASSWORD="$INITIAL_PASSWORD" \
      --dry-run=client -o yaml | $KUBECTL apply -f -)
    $KUBECTL -n ${ns} label secret stirling-pdf-auth k8s/credential=true --overwrite >/dev/null

    echo "$APPLY_OUTPUT"

    STIRLING_SECRET_CHANGED=0
    case "$APPLY_OUTPUT" in
      *configured*) STIRLING_SECRET_CHANGED=1 ;;
    esac
  '';

  extraScript = ''
    if [ "$STIRLING_SECRET_CHANGED" = "1" ]; then
      echo "stirling-pdf-auth changed, restarting the deployment so it picks the new values up..."
      $KUBECTL -n ${ns} rollout restart deploy/stirling-pdf
      $KUBECTL -n ${ns} rollout status deploy/stirling-pdf --timeout=300s
    fi
  '';

  release = k8s.createHelmRelease {
    name = "stirling-pdf";
    namespace = ns;
    tier = "extras";
    chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
    version = "4.6.1";
    valuesFile = ./values.yaml;
    waitFor = "stirling-pdf";
    timeout = "15m";
    inherit preScript extraScript;
    ingress = {
      host = "pdf";
      service = "stirling-pdf";
      port = 8080;
    };
  };
in
lib.recursiveUpdate release {
  sso.oidcApps = [
    {
      name = "Stirling PDF";
      slug = "stirling-pdf";
      host = "pdf";
      namespace = ns;
      redirectPaths = [ "/login/oauth2/code/oidc" ];
    }
  ];

  systemd.services.stirling-pdf-setup = {
    after = release.systemd.services.stirling-pdf-setup.after ++ [ "authentik-sso-setup.service" ];
    wants = [ "authentik-sso-setup.service" ];
  };
}
