{
  config,
  k8s,
  lib,
  pkgs,
  ...
}:

let
  ns = "extra";
  deployName = "paperless";
  podLabel = "app.kubernetes.io/name=paperless";
  dbPath = "/usr/src/paperless/data/db.sqlite3";
  backupRoot = "${k8s.primaryNasMountPoint}/backups";
  backupDir = "${backupRoot}/paperless";
  retentionDays = 30;

  mountUnit = path: "${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" path)}.mount";
  nasMountUnit = mountUnit k8s.primaryNasMountPoint;

  backupRootIsBind = lib.any (
    cfg: (cfg.enabled or false) && lib.elem "backups" (cfg.mediaPaths or [ ])
  ) (lib.attrValues config.cluster.nas);

  backupRootUnit = lib.optional (config.cluster.storage.useNFS && backupRootIsBind) (
    mountUnit backupRoot
  );

  kubectl = "${pkgs.kubectl}/bin/kubectl";
  mountpoint = "${pkgs.util-linux}/bin/mountpoint";

  backupScript = pkgs.writeShellScript "${deployName}-backup" ''
    set -euo pipefail
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    echo "=== Paperless SQLite backup ==="

    if ! ${mountpoint} -q ${k8s.primaryNasMountPoint}; then
      echo "ERROR: ${k8s.primaryNasMountPoint} not mounted, aborting"
      exit 1
    fi
    ${lib.optionalString backupRootIsBind ''
      if ! ${mountpoint} -q ${backupRoot}; then
        echo "ERROR: ${backupRoot} is not a mount point; the NAS bind mount is"
        echo "missing and writing here would land on the wrong disk. Aborting."
        exit 1
      fi
    ''}

    mkdir -p "${backupDir}"

    POD=$(${kubectl} -n ${ns} get pod -l ${podLabel} \
      -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null \
      | ${pkgs.coreutils}/bin/tr ' ' '\n' | ${pkgs.coreutils}/bin/head -1)

    if [ -z "$POD" ]; then
      echo "ERROR: no Running ${deployName} pod found in ${ns}"
      exit 1
    fi
    echo "Target pod: $POD"

    DATE=$(${pkgs.coreutils}/bin/date -u +%Y-%m-%d)
    SNAP="/tmp/paperless-$DATE.db"
    DEST="${backupDir}/paperless-$DATE.db.gz"

    echo "Taking SQLite snapshot inside pod..."
    ${kubectl} -n ${ns} exec "$POD" -c main -- python3 -c \
      'import sqlite3, sys; src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2]); src.backup(dst); dst.close(); src.close()' \
      "${dbPath}" "$SNAP"

    echo "Streaming snapshot to the NAS..."
    ${kubectl} -n ${ns} exec "$POD" -c main -- gzip -c "$SNAP" > "$DEST"

    ${kubectl} -n ${ns} exec "$POD" -c main -- rm -f "$SNAP" || true

    if [ ! -s "$DEST" ]; then
      echo "ERROR: backup file is empty: $DEST"
      rm -f "$DEST"
      exit 1
    fi

    if ! ${pkgs.gzip}/bin/gzip -t "$DEST"; then
      echo "ERROR: backup file is not a valid gzip stream: $DEST"
      rm -f "$DEST"
      exit 1
    fi

    SIZE=$(${pkgs.coreutils}/bin/du -h "$DEST" | ${pkgs.coreutils}/bin/cut -f1)
    echo "Backup written: $DEST ($SIZE)"

    echo "Pruning backups older than ${toString retentionDays} days..."
    ${pkgs.findutils}/bin/find "${backupDir}" -maxdepth 1 \
      -name 'paperless-*.db.gz' -type f \
      -mtime +${toString retentionDays} -print -delete || true

    echo "Done."
  '';
in
{
  systemd.services."${deployName}-backup" = {
    description = "Daily backup of the Paperless SQLite database to the NAS";
    after = [
      "k3s-extras.target"
    ]
    ++ lib.optionals config.cluster.storage.useNFS [ nasMountUnit ]
    ++ backupRootUnit;
    wants = lib.optionals config.cluster.storage.useNFS [ nasMountUnit ] ++ backupRootUnit;

    serviceConfig = {
      Type = "oneshot";
      ExecStart = backupScript;
    };
  };

  systemd.timers."${deployName}-backup" = {
    description = "Daily Paperless SQLite backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:45:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };
}
