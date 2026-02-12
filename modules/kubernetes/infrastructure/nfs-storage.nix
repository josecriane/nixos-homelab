# NFS Storage Integration for Media Services
# Mounts NAS at /mnt/nas1 via system fileSystems, then uses hostPath PVs
# Follows TRaSH Guides structure: /data/torrents/* and /data/media/*
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "media";
  markerFile = "/var/lib/nfs-storage-setup-done";

  # Check if NFS storage is enabled
  useNFS = serverConfig.storage.useNFS or false;

  # Get primary NAS configuration (first enabled NAS with media role)
  enabledNas = lib.filterAttrs (name: cfg: cfg.enabled or false) (serverConfig.nas or { });
  mediaNas = lib.findFirst (
    cfg: (cfg.role or "all") == "media" || (cfg.role or "all") == "all"
  ) null (lib.attrValues enabledNas);

  # NFS server IP
  nfsServer = if mediaNas != null then mediaNas.ip else "";
  nfsExports = if mediaNas != null then (mediaNas.nfsExports or { }) else { };

  # NFSv4 path: if using fsid=0 on NAS, use "/" as the mount path
  nfsPath = nfsExports.nfsPath or "/";

  # Secondary NAS configs (have mediaPaths for bind-mounting into primary NAS tree)
  secondaryNasList = lib.filter (
    cfg: (cfg.enabled or false) && (cfg.mediaPaths or [ ]) != [ ] && cfg != mediaNas
  ) (lib.attrValues (serverConfig.nas or { }));

  # NAS configs with cloudPaths (for cloud service PVs)
  cloudNasList = lib.filter (cfg: (cfg.enabled or false) && (cfg.cloudPaths or { }) != { }) (
    lib.attrValues (serverConfig.nas or { })
  );

  # Host paths
  nasMountPoint = "/mnt/nas1";
  localDataPath = "/var/lib/media-data";

  # The actual data path used by PVs (NAS mount or local)
  hostDataPath = if useNFS then nasMountPoint else localDataPath;

  # Systemd mount unit names for secondary NAS mounts and their bind mounts
  pathToMountUnit =
    path: (builtins.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" path)) + ".mount";

  secondaryMountUnits = lib.concatMap (
    nasCfg:
    [ (pathToMountUnit "/mnt/${nasCfg.hostname}") ]
    ++ map (path: pathToMountUnit "${nasMountPoint}/${path}") nasCfg.mediaPaths
  ) secondaryNasList;

in
{
  # Enable NFS client support
  boot.supportedFilesystems = lib.mkIf useNFS [
    "nfs"
    "nfs4"
  ];
  services.rpcbind.enable = lib.mkIf useNFS true;

  # Mount NAS at /mnt/nas1 (nofail so boot continues if NAS is down)
  fileSystems = lib.mkIf useNFS (
    {
      ${nasMountPoint} = {
        device = "${nfsServer}:${nfsPath}";
        fsType = "nfs4";
        options = [
          "rw"
          "noatime"
          "nodiratime"
          "soft"
          "timeo=50"
          "retrans=3"
          "_netdev"
          "nofail"
        ];
      };
    }
    # Secondary NAS mounts + bind mounts into primary NAS tree
    // lib.foldl' (
      acc: nasCfg:
      let
        nasMount = "/mnt/${nasCfg.hostname}";
        nasNfsPath = (nasCfg.nfsExports or { }).nfsPath or "/";
      in
      acc
      // {
        ${nasMount} = {
          device = "${nasCfg.ip}:${nasNfsPath}";
          fsType = "nfs4";
          options = [
            "rw"
            "noatime"
            "nodiratime"
            "soft"
            "timeo=50"
            "retrans=3"
            "_netdev"
            "nofail"
          ];
        };
      }
      // lib.foldl' (
        a: path:
        a
        // {
          "${nasMountPoint}/${path}" = {
            device = "${nasMount}/${path}";
            options = [
              "bind"
              "_netdev"
              "nofail"
            ];
            depends = [
              nasMountPoint
              nasMount
            ];
          };
        }
      ) { } nasCfg.mediaPaths
    ) { } secondaryNasList
  );

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
                setup_namespace "${ns}"

                USE_NFS="${if useNFS then "true" else "false"}"
                HOST_DATA_PATH="${hostDataPath}"

                echo "Storage mode: $([ "$USE_NFS" = "true" ] && echo "NFS (${nfsServer} → ${nasMountPoint})" || echo "Local ($HOST_DATA_PATH)")"

                ${
                  if useNFS then
                    ''
                      # Verify NAS mount is available
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

                # Create directory structure
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
                # Set 777 on directories only (recursive chmod on files is too slow over NFS)
                find "$HOST_DATA_PATH/torrents" "$HOST_DATA_PATH/media" -type d -exec chmod 775 {} + 2>/dev/null || true
                echo "Directory structure created at $HOST_DATA_PATH"

                # Create PV + PVC if not already Bound
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

                  # Wait for PVC to be Bound
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
                                chmod 775 "${hostPath}" 2>/dev/null || true
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
