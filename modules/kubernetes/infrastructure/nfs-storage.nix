# Homelab NFS storage: shared-data PVC (TRaSH Guides layout) + cloud PVs.
# Mounts, rpcbind and nfs-heal come from nixos-k8s/infrastructure/nfs-mounts.nix.
{
  config,
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "media";
  markerFile = "/var/lib/nfs-storage-setup-done";

  useNFS = serverConfig.storage.useNFS or false;

  enabledNas = lib.filterAttrs (name: cfg: cfg.enabled or false) (serverConfig.nas or { });
  mediaNas = lib.findFirst (
    cfg: (cfg.role or "all") == "media" || (cfg.role or "all") == "all"
  ) null (lib.attrValues enabledNas);
  nfsServer = if mediaNas != null then mediaNas.ip else "";

  secondaryNasList = lib.filter (
    cfg: (cfg.enabled or false) && (cfg.mediaPaths or [ ]) != [ ] && cfg != mediaNas
  ) (lib.attrValues (serverConfig.nas or { }));

  cloudNasList = lib.filter (cfg: (cfg.enabled or false) && (cfg.cloudPaths or { }) != { }) (
    lib.attrValues (serverConfig.nas or { })
  );

  nasMountPoint = "/mnt/nas1";
  localDataPath = "/var/lib/media-data";
  hostDataPath = if useNFS then nasMountPoint else localDataPath;

  pathToMountUnit =
    path: (builtins.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" path)) + ".mount";

  secondaryMountUnits = lib.concatMap (
    nasCfg:
    [ (pathToMountUnit "/mnt/${nasCfg.hostname}") ]
    ++ map (path: pathToMountUnit "${nasMountPoint}/${path}") nasCfg.mediaPaths
  ) secondaryNasList;
in
{
  systemd.services.nfs-storage-setup = {
    description = "Setup storage for media services";
    after = [
      "k3s-infrastructure.target"
    ]
    ++ lib.optionals useNFS ([ "mnt-nas1.mount" ] ++ secondaryMountUnits);
    requires = [ "k3s-infrastructure.target" ];
    wants = lib.optionals useNFS ([ "mnt-nas1.mount" ] ++ secondaryMountUnits);
    # TIER 2: Storage
    wantedBy = [ "k3s-storage.target" ];
    before = [ "k3s-storage.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nfs-storage-setup" ''
                ${k8s.libShSource}

                setup_preamble "${markerFile}" "NFS Storage"
                wait_for_k3s
                ensure_namespace "${ns}"

                USE_NFS="${if useNFS then "true" else "false"}"
                HOST_DATA_PATH="${hostDataPath}"

                echo "Storage mode: $([ "$USE_NFS" = "true" ] && echo "NFS (${nfsServer} -> ${nasMountPoint})" || echo "Local ($HOST_DATA_PATH)")"

                ${
                  if useNFS then
                    ''
                      MOUNTPOINT="${pkgs.util-linux}/bin/mountpoint"
                      if ! $MOUNTPOINT -q "${nasMountPoint}"; then
                        echo "WARN: ${nasMountPoint} not mounted, attempting to mount..."
                        mount "${nasMountPoint}" 2>/dev/null || true
                        sleep 3
                      fi

                      if ! $MOUNTPOINT -q "${nasMountPoint}"; then
                        echo "ERROR: Could not mount ${nasMountPoint}, using local storage..."
                        HOST_DATA_PATH="${localDataPath}"
                        USE_NFS="false"
                      fi
                    ''
                  else
                    ""
                }

                # TRaSH Guides directory layout
                echo "Creating TRaSH Guides directory structure..."
                mkdir -p "$HOST_DATA_PATH/torrents/movies"
                mkdir -p "$HOST_DATA_PATH/torrents/tv"
                mkdir -p "$HOST_DATA_PATH/torrents/music"
                mkdir -p "$HOST_DATA_PATH/torrents/books"
                mkdir -p "$HOST_DATA_PATH/torrents/incomplete"
                mkdir -p "$HOST_DATA_PATH/media/movies"
                mkdir -p "$HOST_DATA_PATH/media/movies-es"
                mkdir -p "$HOST_DATA_PATH/media/tv"
                mkdir -p "$HOST_DATA_PATH/media/tv-es"
                mkdir -p "$HOST_DATA_PATH/media/music"
                mkdir -p "$HOST_DATA_PATH/media/books"
                mkdir -p "$HOST_DATA_PATH/backups"
                # Only top-level chmod (recursive chmod is too slow over NFS)
                chmod 775 "$HOST_DATA_PATH/torrents" "$HOST_DATA_PATH/media" 2>/dev/null || true
                for d in "$HOST_DATA_PATH"/torrents/* "$HOST_DATA_PATH"/media/*; do
                  [ -d "$d" ] && chmod 775 "$d" 2>/dev/null || true
                done
                echo "Directory structure created at $HOST_DATA_PATH"

                # shared-data PV/PVC in media namespace (ReadWriteMany)
                EXISTING_STATUS=$($KUBECTL get pvc shared-data -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$EXISTING_STATUS" = "Bound" ]; then
                  echo "PV/PVC shared-data already exists and is Bound, skipping creation"
                else
                  STORAGE_CLASS="local-storage"
                  STORAGE_SIZE="500Gi"
                  if [ "$USE_NFS" = "true" ]; then
                    STORAGE_SIZE="1Ti"
                  fi

                  cat <<PVEOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: PersistentVolume
        metadata:
          name: shared-data-pv
          labels:
            type: local
        spec:
          capacity:
            storage: $STORAGE_SIZE
          accessModes:
            - ReadWriteMany
          persistentVolumeReclaimPolicy: Retain
          storageClassName: $STORAGE_CLASS
          hostPath:
            path: $HOST_DATA_PATH
            type: DirectoryOrCreate
        ---
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: shared-data
          namespace: ${ns}
        spec:
          accessModes:
            - ReadWriteMany
          storageClassName: $STORAGE_CLASS
          resources:
            requests:
              storage: $STORAGE_SIZE
          volumeName: shared-data-pv
        PVEOF
                  echo "PV/PVC shared-data created (hostPath: $HOST_DATA_PATH)"

                  echo "Waiting for PVC shared-data to be Bound..."
                  for i in $(seq 1 30); do
                    STATUS=$($KUBECTL get pvc shared-data -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
                    if [ "$STATUS" = "Bound" ]; then
                      echo "PVC shared-data: Bound"
                      break
                    fi
                    echo "  Status: $STATUS ($i/30)"
                    sleep 5
                  done
                fi

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

                print_success "NFS Storage" \
                  "PVC: shared-data (${ns})" \
                  "TRaSH Guides structure:" \
                  "  /data/torrents/{movies,tv,music,books}" \
                  "  /data/media/{movies,tv,music,books}"

                create_marker "${markerFile}"
      '';
    };
  };
}
