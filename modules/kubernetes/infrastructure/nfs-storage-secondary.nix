{
  k8s,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  markerFile = "/var/lib/nfs-storage-secondary-setup-done";
  ns = "media";
  paths = import ../media-paths.nix { inherit lib k8s serverConfig; };

  createVolume =
    cfg:
    let
      pvcName = paths.claimName cfg;
      pvName = "${pvcName}-pv";
      hostPath = k8s.nasMountPointOf cfg;
    in
    ''
      if ! $MOUNTPOINT -q "${hostPath}"; then
        mount "${hostPath}" 2>/dev/null || true
        sleep 3
      fi
      if ! $MOUNTPOINT -q "${hostPath}"; then
        echo "ERROR: ${hostPath} is not mounted, cannot create ${pvName}"
        exit 1
      fi

      EXISTING_STATUS=$($KUBECTL get pvc ${pvcName} -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      if [ "$EXISTING_STATUS" = "Bound" ]; then
        echo "PV/PVC ${pvcName} already exists and is Bound, skipping"
      else
        cat <<PVEOF | $KUBECTL apply -f -
      apiVersion: v1
      kind: PersistentVolume
      metadata:
        name: ${pvName}
      spec:
        capacity:
          storage: 1Ti
        accessModes:
          - ReadWriteMany
        persistentVolumeReclaimPolicy: Retain
        storageClassName: nas-storage
        hostPath:
          path: ${hostPath}
          type: Directory
      ---
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: ${pvcName}
        namespace: ${ns}
      spec:
        accessModes:
          - ReadWriteMany
        storageClassName: nas-storage
        volumeName: ${pvName}
        resources:
          requests:
            storage: 1Ti
      PVEOF
        echo "PV/PVC ${pvcName} created (hostPath: ${hostPath})"
      fi
    '';
in
lib.mkIf (paths.secondary != [ ]) {
  systemd.services.nfs-storage-secondary-setup = {
    description = "Secondary NAS shared-data PVs (one mount per NAS)";
    after = [ "nfs-storage-setup.service" ];
    requires = [ "nfs-storage-setup.service" ];
    wantedBy = [ "k3s-storage.target" ];
    before = [ "k3s-storage.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nfs-storage-secondary-setup" ''
        ${k8s.libShSource}
        MOUNTPOINT="${pkgs.util-linux}/bin/mountpoint"

        setup_preamble "${markerFile}" "Secondary NAS PVs"
        wait_for_k3s
        ensure_namespace ${ns}

        ${lib.concatMapStringsSep "\n" createVolume paths.secondary}

        print_success "Secondary NAS PVs" \
          ${lib.concatMapStringsSep " \\\n          " (
            cfg: ''"${paths.claimName cfg}: ${k8s.nasMountPointOf cfg} -> ${paths.mountPoint cfg}"''
          ) paths.secondary}

        create_marker "${markerFile}"
      '';
    };
  };
}
