{
  config,
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

# Cloud PVs (nextcloud/immich/...) backed by hostPaths on secondary NAS mounts.
# These are homelab-specific: multiple NAS units each exposing its own cloud
# path via cloudPaths attr. Runs after upstream's nfs-storage-setup so the
# main PVC is already bound.

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  markerFile = "/var/lib/nfs-storage-cloud-setup-done";

  cloudNasList = lib.filter (cfg: (cfg.enabled or false) && (cfg.cloudPaths or { }) != { }) (
    lib.attrValues (serverConfig.nas or { })
  );

  hasCloudPVs = cloudNasList != [ ];
in
lib.mkIf hasCloudPVs {
  systemd.services.nfs-storage-cloud-setup = {
    description = "Homelab cloud PV creation (per-NAS)";
    after = [ "nfs-storage-setup.service" ];
    requires = [ "nfs-storage-setup.service" ];
    wantedBy = [ "k3s-storage.target" ];
    before = [ "k3s-storage.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nfs-storage-cloud-setup" ''
        ${k8s.libShSource}

        setup_preamble "${markerFile}" "Cloud PVs"
        wait_for_k3s

        ${lib.concatStrings (
          lib.concatMap (
            nasCfg:
            let
              cloudPaths = nasCfg.cloudPaths or { };
              nasHostname = nasCfg.hostname;
            in
            lib.mapAttrsToList (
              service: path:
              let
                pvName = "${service}-data-pv";
                hostPath = "/mnt/${nasHostname}/${path}";
              in
              ''
                # Cloud PV: ${service} -> ${hostPath}
                mkdir -p "${hostPath}" 2>/dev/null || true
                chmod 777 "${hostPath}" 2>/dev/null || true
                if [ "${service}" = "nextcloud" ]; then
                  chown 33:33 "${hostPath}" 2>/dev/null || true
                fi
                EXISTING_PV=$($KUBECTL get pv ${pvName} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$EXISTING_PV" = "Bound" ] || [ "$EXISTING_PV" = "Available" ]; then
                  echo "PV ${pvName} already exists ($EXISTING_PV), skipping"
                else
                  cat <<CLOUDPVEOF | $KUBECTL apply -f -
                apiVersion: v1
                kind: PersistentVolume
                metadata:
                  name: ${pvName}
                spec:
                  capacity:
                    storage: 1Ti
                  accessModes:
                    - ReadWriteOnce
                  persistentVolumeReclaimPolicy: Retain
                  storageClassName: nas-storage
                  hostPath:
                    path: ${hostPath}
                    type: DirectoryOrCreate
                CLOUDPVEOF
                  echo "PV ${pvName} created (hostPath: ${hostPath})"
                fi
              ''
            ) cloudPaths
          ) cloudNasList
        )}

        print_success "Cloud PVs"
        create_marker "${markerFile}"
      '';
    };
  };
}
