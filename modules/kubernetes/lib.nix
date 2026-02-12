# Shared helpers for Kubernetes modules
# Usage: let k8s = import ./lib.nix { inherit pkgs serverConfig; }; in ...
{ pkgs, serverConfig }:

let
  kubectl = "${pkgs.kubectl}/bin/kubectl";
  helm = "${pkgs.kubernetes-helm}/bin/helm";
  jq = "${pkgs.jq}/bin/jq";
  openssl = "${pkgs.openssl}/bin/openssl";

  domain = serverConfig.domain;
  subdomain = serverConfig.subdomain;
  certSecret = "wildcard-${subdomain}-${domain}-tls";
in
rec {
  # ============================================
  # LIB.SH SOURCE (exports env vars + sources lib.sh)
  # ============================================

  libShSource = ''
    export KUBECTL="${pkgs.kubectl}/bin/kubectl"
    export JQ="${pkgs.jq}/bin/jq"
    export HELM="${pkgs.kubernetes-helm}/bin/helm"
    export OPENSSL="${pkgs.openssl}/bin/openssl"
    export IP="${pkgs.iproute2}/bin/ip"
    export CURL="${pkgs.curl}/bin/curl"
    export DOMAIN="${domain}"
    export SUBDOMAIN="${subdomain}"
    export CERT_SECRET="${certSecret}"
    source ${./lib.sh}
  '';

  # ============================================
  # NIX-PURE FUNCTIONS (cannot be bash)
  # ============================================

  hostname = name: "${name}.${subdomain}.${domain}";

  forwardAuthMiddleware = [
    {
      name = "authentik-forward-auth";
      namespace = "traefik-system";
    }
  ];

  # ============================================
  # DEPLOYMENT FUNCTION (complex YAML templating, stays in Nix)
  # ============================================

  createLinuxServerDeployment =
    {
      name,
      namespace,
      image,
      port,
      configPVC,
      apiKeySecret ? null,
      extraVolumes ? [ ],
      extraVolumeMounts ? [ ],
      extraEnv ? [ ],
      resources ? {
        requests = {
          cpu = "50m";
          memory = "128Mi";
        };
        limits = {
          memory = "512Mi";
        };
      },
    }:
    let
      puid = toString (serverConfig.puid or 1000);
      pgid = toString (serverConfig.pgid or 1000);

      volumeMountsStr = builtins.concatStringsSep "\n        " (
        [
          "- name: config\n          mountPath: /config"
        ]
        ++ extraVolumeMounts
      );

      volumesStr = builtins.concatStringsSep "\n      " (
        [
          "- name: config\n        persistentVolumeClaim:\n          claimName: ${configPVC}"
        ]
        ++ extraVolumes
        ++ (
          if apiKeySecret != null then
            [
              "- name: api-key-secret\n        secret:\n          secretName: ${apiKeySecret}"
            ]
          else
            [ ]
        )
      );

      envStr = builtins.concatStringsSep "\n        " (
        [
          "- name: PUID\n          value: \"${puid}\""
          "- name: PGID\n          value: \"${pgid}\""
          "- name: TZ\n          value: \"${serverConfig.timezone}\""
        ]
        ++ extraEnv
      );

      rawInitContainer = ''
        initContainers:
        - name: init-api-key
          image: busybox:latest
          command: ['sh', '-c']
          args:
          - |
            API_KEY=$(cat /secrets/api-key)
            if [ ! -f /config/config.xml ]; then
              echo "Pre-seeding config.xml with stable API key..."
              cat > /config/config.xml <<XMLEOF
            <Config>
              <ApiKey>''${API_KEY}</ApiKey>
              <AnalyticsEnabled>False</AnalyticsEnabled>
            </Config>
            XMLEOF
              chown ${puid}:${pgid} /config/config.xml
              echo "config.xml created with stable API key"
            else
              CURRENT_KEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' /config/config.xml)
              if [ "$CURRENT_KEY" != "$API_KEY" ]; then
                echo "Updating API key in existing config.xml..."
                sed -i "s|<ApiKey>.*</ApiKey>|<ApiKey>''${API_KEY}</ApiKey>|" /config/config.xml
                echo "API key updated"
              else
                echo "config.xml API key matches secret, no change needed"
              fi
            fi
          volumeMounts:
          - name: config
            mountPath: /config
          - name: api-key-secret
            mountPath: /secrets
            readOnly: true'';

      initContainerYaml =
        if apiKeySecret != null then
          builtins.concatStringsSep "\n" (
            map (line: "      " + line) (
              pkgs.lib.splitString "\n" (pkgs.lib.removePrefix "\n" rawInitContainer)
            )
          )
        else
          "";
    in
    ''
          cat <<'EOF' | ${kubectl} apply -f -
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ${name}
        namespace: ${namespace}
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: ${name}
        template:
          metadata:
            labels:
              app: ${name}
          spec:
      ${initContainerYaml}
            containers:
            - name: ${name}
              image: ${image}
              ports:
              - containerPort: ${toString port}
              env:
              ${envStr}
              resources:
                requests:
                  cpu: ${resources.requests.cpu}
                  memory: ${resources.requests.memory}
                limits:
                  memory: ${resources.limits.memory}
              volumeMounts:
              ${volumeMountsStr}
            volumes:
            ${volumesStr}
      ---
      apiVersion: v1
      kind: Service
      metadata:
        name: ${name}
        namespace: ${namespace}
      spec:
        selector:
          app: ${name}
        ports:
        - port: ${toString port}
          targetPort: ${toString port}
      EOF
    '';
}
