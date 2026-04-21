# Switchboard - browser-based control panel for K8s workloads.
# Consumes the standalone `switchboard` flake (github:josecriane/switchboard or
# a local path override) which provides both a Nix-built OCI image and a
# self-contained manifests bundle. This module imports the image into k3s's
# containerd, overrides the ConfigMap with homelab-specific display hints, and
# runs a scale-down reconciler that enforces disabled services and
# switchboard.io/* annotations after setup scripts re-apply specs.
{
  config,
  lib,
  pkgs,
  serverConfig,
  nodeConfig,
  nixos-k8s,
  switchboard,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "switchboard";
  markerFile = "/var/lib/switchboard-setup-done";
  isBootstrap = nodeConfig.bootstrap or false;

  cfg = config.k8s.apps.switchboard;

  configJson = builtins.toJSON {
    inherit (cfg) groupNames noStop hide;
  };

  switchboardPkgs = switchboard.packages.${pkgs.system};
  image = switchboardPkgs.dockerImage;

  # Upstream manifest ships with the GHCR image + IfNotPresent so it works
  # standalone. Here we patch it to consume the locally-imported image with
  # pullPolicy: Never (containerd already has it via ctr images import).
  patchedManifest = pkgs.writeText "switchboard-manifests.yaml" (
    builtins.replaceStrings
      [
        "image: ghcr.io/josecriane/switchboard:latest"
        "imagePullPolicy: IfNotPresent"
      ]
      [
        "image: docker.io/library/switchboard:latest"
        "imagePullPolicy: Never"
      ]
      (builtins.readFile (switchboardPkgs.manifests + "/manifests.yaml"))
  );

  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;

  serviceNamespaces = {
    authentik = [ "authentik" ];
    media = [ "media" ];
    immich = [ "immich" ];
    syncthing = [ "syncthing" ];
    monitoring = [ "monitoring" ];
    vaultwarden = [ "vaultwarden" ];
    nextcloud = [ "nextcloud" ];
    kiwix = [ "kiwix" ];
    openstreetmap = [ "openstreetmap" ];
  };

  disabledNamespaces = lib.concatLists (
    lib.mapAttrsToList (name: namespaces: if enabled name then [ ] else namespaces) serviceNamespaces
  );

  # Scales every workload with switchboard.io/user-paused=true back to 0.
  # Invoked via systemd OnSuccess= from each setup service so paused pods
  # get put back to sleep right after helm/kubectl bring them up, without
  # waiting for the end-of-boot service-scaledown reconciler.
  pausedReconcilerScript = pkgs.writeShellScript "switchboard-paused-reconciler" ''
    ${k8s.libShSource}
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    for kind in deployments statefulsets; do
      $KUBECTL get "$kind" -A -o json 2>/dev/null | $JQ -r \
        '.items[] | select(.metadata.annotations["switchboard.io/user-paused"] == "true" and (.spec.replicas // 0) > 0)
         | "\(.metadata.namespace) \(.metadata.name)"' | \
      while read -r ns name; do
        [ -z "$ns" ] && continue
        echo "Re-pausing $kind $ns/$name"
        $KUBECTL scale "$kind/$name" -n "$ns" --replicas=0 2>/dev/null || true
      done
    done
  '';
in
{
  options.k8s.apps.switchboard = {
    hostname = lib.mkOption {
      type = lib.types.str;
      default = "services";
      description = "Subdomain prefix passed to k8s.hostname for the IngressRoute.";
    };
    groupNames = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Map of namespace -> display group name shown in the UI.";
    };
    noStop = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of ns/name (or ns/*) entries that cannot be scaled to 0.";
    };
    hide = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Namespaces to hide entirely from the UI.";
    };
  };

  config = {
    k8s.apps.switchboard = {
      hostname = "services";
      groupNames = {
        "kube-system" = "System";
        "traefik-system" = "Infrastructure";
        "cert-manager" = "Infrastructure";
        "metallb-system" = "Infrastructure";
        "switchboard" = "Dashboard";
        "homer" = "Dashboard";
      };
      noStop = [
        "kube-system/*"
        "traefik-system/traefik"
        "cert-manager/*"
        "metallb-system/*"
        "homer/homer"
        "switchboard/switchboard"
      ];
      hide = [ "default" ];
    };

    systemd.services = lib.mkMerge [
      {
        switchboard-image-import = {
          description = "Import Switchboard container image into containerd";
          after = [ "k3s.service" ];
          requires = [ "k3s.service" ];
          wantedBy = [ "multi-user.target" ];
          restartTriggers = [ image ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "switchboard-image-import" ''
              set -e
              for i in $(seq 1 60); do
                [ -S /run/k3s/containerd/containerd.sock ] && break
                sleep 2
              done
              echo "Importing Switchboard image..."
              ${pkgs.k3s}/bin/k3s ctr images import ${image}
            '';
          };
        };
      }
      (lib.optionalAttrs isBootstrap {
        switchboard-setup = {
          description = "Setup Switchboard";
          after = [
            "k3s-storage.target"
            "switchboard-image-import.service"
          ];
          requires = [
            "k3s-storage.target"
            "switchboard-image-import.service"
          ];
          wantedBy = [ "k3s-core.target" ];
          before = [ "k3s-core.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "switchboard-setup" ''
              ${k8s.libShSource}
              IMAGE_HASH="${image}"
              setup_preamble_hash "${markerFile}" "Switchboard" "$IMAGE_HASH"

              wait_for_k3s
              wait_for_traefik
              wait_for_certificate

              $KUBECTL apply -f ${patchedManifest}

              # Overwrite ConfigMap with homelab-specific display hints.
              $KUBECTL create configmap switchboard-config -n ${ns} \
                --from-literal=services.json='${configJson}' \
                --dry-run=client -o yaml | $KUBECTL apply -f -

              wait_for_deployment "${ns}" "switchboard" 120

              echo "Rolling out switchboard to pick up new image..."
              $KUBECTL rollout restart deployment/switchboard -n ${ns}
              $KUBECTL rollout status deployment/switchboard -n ${ns} --timeout=120s

              create_ingress_route "switchboard" "${ns}" "$(hostname ${cfg.hostname})" "switchboard" "8080"

              print_success "Switchboard" \
                "URL: https://$(hostname ${cfg.hostname})"

              create_marker "${markerFile}" "$IMAGE_HASH"
            '';
          };
        };

        switchboard-paused-reconciler = {
          description = "Re-pause workloads tagged switchboard.io/user-paused";
          after = [ "k3s.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = pausedReconcilerScript;
          };
        };

        service-scaledown =
          let
            excluded = [
              "service-scaledown"
              "switchboard-paused-reconciler"
            ];
            setupServices = lib.attrNames (
              lib.filterAttrs (
                n: svc:
                !(builtins.elem n excluded) && builtins.any (t: lib.hasPrefix "k3s-" t) (svc.wantedBy or [ ])
              ) config.systemd.services
            );
            setupUnits = map (n: "${n}.service") setupServices;
          in
          {
            description = "Scale down disabled services";
            after = [ "k3s-extras.target" ] ++ setupUnits;
            requires = [ "k3s-extras.target" ];
            wantedBy = [ "multi-user.target" ];

            restartTriggers = [
              (builtins.toJSON (serverConfig.services or { }))
            ]
            ++ (map (n: config.systemd.services.${n}.serviceConfig.ExecStart or "") setupServices);

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "service-scaledown" ''
                ${k8s.libShSource}
                export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

                echo "Scaling down disabled services..."
                ${lib.concatMapStringsSep "\n" (namespace: ''
                  echo "Scaling down namespace: ${namespace}"
                  for resource in $($KUBECTL get deployments,statefulsets -n ${namespace} -o name 2>/dev/null); do
                    $KUBECTL scale "$resource" --replicas=0 -n ${namespace} 2>/dev/null || true
                  done
                  for ds in $($KUBECTL get daemonsets -n ${namespace} -o name 2>/dev/null); do
                    $KUBECTL patch "$ds" -n ${namespace} -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing":"true"}}}}}' 2>/dev/null || true
                  done
                '') disabledNamespaces}

                echo "Enforcing user-paused annotation across all namespaces..."
                for kind in deployments statefulsets; do
                  $KUBECTL get "$kind" -A -o json 2>/dev/null | $JQ -r \
                    '.items[] | select(.metadata.annotations["switchboard.io/user-paused"] == "true")
                     | "\(.metadata.namespace) \(.metadata.name)"' | \
                  while read -r ns name; do
                    [ -z "$ns" ] && continue
                    echo "Preserving paused: $kind $ns/$name"
                    $KUBECTL scale "$kind/$name" -n "$ns" --replicas=0 2>/dev/null || true
                  done
                done
                $KUBECTL get daemonsets -A -o json 2>/dev/null | $JQ -r \
                  '.items[] | select(.metadata.annotations["switchboard.io/user-paused"] == "true")
                   | "\(.metadata.namespace) \(.metadata.name)"' | \
                while read -r ns name; do
                  [ -z "$ns" ] && continue
                  echo "Preserving paused: daemonset $ns/$name"
                  $KUBECTL patch "daemonset/$name" -n "$ns" \
                    -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing":"true"}}}}}' 2>/dev/null || true
                done

                echo "Enforcing preferred-node annotation..."
                for kind in deployments statefulsets; do
                  $KUBECTL get "$kind" -A -o json 2>/dev/null | $JQ -r \
                    '.items[] | select(.metadata.annotations["switchboard.io/preferred-node"] != null and .metadata.annotations["switchboard.io/preferred-node"] != "")
                     | "\(.metadata.namespace) \(.metadata.name) \(.metadata.annotations["switchboard.io/preferred-node"])"' | \
                  while read -r ns name node; do
                    [ -z "$ns" ] && continue
                    echo "Pinning preference: $kind $ns/$name -> $node"
                    patch=$($JQ -nc --arg node "$node" '{spec:{template:{spec:{affinity:{nodeAffinity:{preferredDuringSchedulingIgnoredDuringExecution:[{weight:100,preference:{matchExpressions:[{key:"kubernetes.io/hostname",operator:"In",values:[$node]}]}}]}}}}}}')
                    $KUBECTL patch "$kind/$name" -n "$ns" --type=merge -p "$patch" 2>/dev/null || true
                  done
                done

                echo "Scale-down complete"
              '';
            };
          };
      })
    ];

    # Timer-driven reconciliation. service-scaledown only runs at end of boot
    # (after k3s-extras.target + all setups), leaving a long window during a
    # make deploy where helm upgrade brings paused pods back up. This timer
    # re-runs the paused-only enforcement every 30s so paused pods go back
    # to 0 within seconds of helm finishing, not after the whole deploy.
    systemd.timers = lib.mkIf isBootstrap {
      switchboard-paused-reconciler = {
        description = "Periodically re-pause workloads tagged user-paused";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "30s";
          AccuracySec = "5s";
        };
      };
    };
  };
}
