# Backup system using Restic + systemd timers
# Stores backups on NAS at /mnt/nas1/backups/restic-repo
# Tiers: Critical (daily 03:00), Full (weekly Sun 04:00), Cleanup (weekly Sun 06:00)
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  kubectl = "${pkgs.kubectl}/bin/kubectl";
  restic = "${pkgs.restic}/bin/restic";
  gzip = "${pkgs.gzip}/bin/gzip";
  gunzip = "${pkgs.gzip}/bin/gunzip";
  mountpoint = "${pkgs.util-linux}/bin/mountpoint";

  # Backup paths
  resticRepo = "/mnt/nas1/backups/restic-repo";
  passwordFile = "/var/lib/backup/restic-password";
  dumpDir = "/var/lib/backup/db-dumps";
  k3sStorage = "/var/lib/rancher/k3s/storage";

  # Restic env
  resticEnv = ''
    export RESTIC_REPOSITORY="${resticRepo}"
    export RESTIC_PASSWORD_FILE="${passwordFile}"
  '';

  # PostgreSQL instances to dump
  # Format: namespace, pod/deploy selector, user, database
  pgDumps = [
    {
      ns = "authentik";
      pod = "authentik-postgresql-0";
      user = "authentik";
      db = "authentik";
    }
    {
      ns = "nextcloud";
      pod = "nextcloud-postgresql-0";
      user = "nextcloud";
      db = "nextcloud";
    }
    {
      ns = "immich";
      deploy = "immich-postgres";
      user = "immich";
      db = "immich";
    }
  ];

  # Exclusions for full backup (media, transcodes, downloads)
  excludePatterns = [
    "*/media-library/*"
    "*jellyfin*/data/transcodes/*"
    "*qbittorrent*/downloads/*"
    "*.tmp"
    "*.log"
  ];

  excludeFile = pkgs.writeText "backup-excludes" (builtins.concatStringsSep "\n" excludePatterns);

  # Shared dump script (used by backup-db-dump service and as ExecStartPre in backup-critical)
  dumpScript = pkgs.writeShellScript "backup-db-dump" ''
    set -e
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    echo "=== Database Dumps ==="
    mkdir -p "${dumpDir}"
    mkdir -p "${dumpDir}/k8s-secrets"

    # PostgreSQL dumps
    ${builtins.concatStringsSep "\n" (
      map (
        pg:
        let
          execTarget = if pg ? deploy then "deploy/${pg.deploy}" else pg.pod;
        in
        ''
          echo "Dumping ${pg.db} (${pg.ns})..."
          if ${kubectl} get ${
            if pg ? deploy then "deploy/${pg.deploy}" else "pod/${pg.pod}"
          } -n ${pg.ns} &>/dev/null; then
            ${kubectl} exec -n ${pg.ns} ${execTarget} -- \
              pg_dump -U ${pg.user} -d ${pg.db} 2>/dev/null | ${gzip} > "${dumpDir}/${pg.db}.sql.gz"
            echo "  ${pg.db}: $(du -h "${dumpDir}/${pg.db}.sql.gz" | cut -f1)"
          else
            echo "  WARN: ${execTarget} not found in ${pg.ns}, skipping"
          fi
        ''
      ) pgDumps
    )}

    # Vaultwarden SQLite backup (copy the raw data directory)
    echo "Backing up Vaultwarden SQLite..."
    VAULTWARDEN_PVC=$(ls -d ${k3sStorage}/pvc-*_vaultwarden_* 2>/dev/null | head -1)
    if [ -n "$VAULTWARDEN_PVC" ] && [ -d "$VAULTWARDEN_PVC" ]; then
      mkdir -p "${dumpDir}/vaultwarden"
      cp "$VAULTWARDEN_PVC/db.sqlite3" "${dumpDir}/vaultwarden/" 2>/dev/null || true
      cp "$VAULTWARDEN_PVC/db.sqlite3-wal" "${dumpDir}/vaultwarden/" 2>/dev/null || true
      cp "$VAULTWARDEN_PVC/db.sqlite3-shm" "${dumpDir}/vaultwarden/" 2>/dev/null || true
      if [ -d "$VAULTWARDEN_PVC/attachments" ]; then
        cp -r "$VAULTWARDEN_PVC/attachments" "${dumpDir}/vaultwarden/" 2>/dev/null || true
      fi
      echo "  Vaultwarden: $(du -sh "${dumpDir}/vaultwarden" | cut -f1)"
    else
      echo "  WARN: Vaultwarden PVC not found, skipping"
    fi

    # K8s Secrets backup (all namespaces)
    echo "Backing up K8s Secrets..."
    for NS in authentik cert-manager homarr immich media monitoring nextcloud syncthing traefik-system uptime-kuma vaultwarden; do
      if ${kubectl} get namespace "$NS" &>/dev/null; then
        ${kubectl} get secrets -n "$NS" -o yaml > "${dumpDir}/k8s-secrets/$NS-secrets.yaml" 2>/dev/null || true
      fi
    done

    # Credential secrets backup (all namespaces, labeled)
    ${kubectl} get secrets --all-namespaces -l homelab/credential=true -o yaml \
      > "${dumpDir}/k8s-secrets/all-credentials.yaml" 2>/dev/null || true
    echo "  K8s Secrets: $(du -sh "${dumpDir}/k8s-secrets" | cut -f1)"

    echo ""
    echo "All dumps completed: $(du -sh "${dumpDir}" | cut -f1) total"
  '';

in
{
  # Helper scripts available system-wide
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "backup-status" ''
      ${resticEnv}
      echo "=== Backup System Status ==="
      echo ""

      # Check NAS mount
      if ${mountpoint} -q /mnt/nas1 2>/dev/null; then
        echo "NAS mount: OK (/mnt/nas1)"
      else
        echo "NAS mount: NOT MOUNTED"
      fi

      # Check repo
      if [ -d "${resticRepo}" ]; then
        echo "Restic repo: exists"
        ${restic} stats --mode raw-data 2>/dev/null && true
      else
        echo "Restic repo: NOT FOUND"
      fi

      echo ""
      echo "=== Recent Snapshots ==="
      ${restic} snapshots --latest 10 2>/dev/null || echo "No snapshots found"

      echo ""
      echo "=== Systemd Timers ==="
      systemctl list-timers 'backup-*' --no-pager 2>/dev/null || true

      echo ""
      echo "=== Last Backup Logs ==="
      echo "--- Critical (daily) ---"
      journalctl -u backup-critical.service --no-pager -n 5 2>/dev/null || true
      echo "--- Full (weekly) ---"
      journalctl -u backup-full.service --no-pager -n 5 2>/dev/null || true
    '')

    (pkgs.writeShellScriptBin "backup-now" ''
      ${resticEnv}
      echo "=== Manual Backup ==="
      echo ""
      echo "1) Critical only (Vaultwarden + DB dumps + K8s Secrets)"
      echo "2) Full (all PVC data)"
      echo "3) Both (critical + full)"
      echo ""
      read -p "Option [1-3]: " OPTION

      case "$OPTION" in
        1)
          echo "Running DB dumps..."
          sudo systemctl start backup-db-dump.service
          echo "Running critical backup..."
          sudo systemctl start backup-critical.service
          ;;
        2)
          echo "Running full backup..."
          sudo systemctl start backup-full.service
          ;;
        3)
          echo "Running DB dumps..."
          sudo systemctl start backup-db-dump.service
          echo "Running critical backup..."
          sudo systemctl start backup-critical.service
          echo "Running full backup..."
          sudo systemctl start backup-full.service
          ;;
        *)
          echo "Invalid option"
          exit 1
          ;;
      esac

      echo ""
      echo "Backup completed. Run 'backup-status' to verify."
    '')

    (pkgs.writeShellScriptBin "backup-restore" ''
      ${resticEnv}
      echo "=== Backup Restore ==="
      echo ""
      echo "Available snapshots:"
      ${restic} snapshots 2>/dev/null || { echo "No snapshots found"; exit 1; }

      echo ""
      read -p "Snapshot ID to restore: " SNAP_ID

      if [ -z "$SNAP_ID" ]; then
        echo "No snapshot ID provided"
        exit 1
      fi

      RESTORE_DIR=$(mktemp -d)


      echo "Restoring snapshot $SNAP_ID to $RESTORE_DIR..."
      ${restic} restore "$SNAP_ID" --target "$RESTORE_DIR"

      echo ""
      echo "Restored to: $RESTORE_DIR"
      echo ""
      echo "Contents:"
      ls -la "$RESTORE_DIR"

      echo ""
      echo "=== Next steps ==="
      echo ""
      echo "For DB dumps (PostgreSQL):"
      echo "  ${gunzip} -c $RESTORE_DIR/db-dumps/<service>.sql.gz | kubectl exec -i -n <ns> <pod> -- psql -U <user> -d <db>"
      echo ""
      echo "For Vaultwarden (SQLite):"
      echo "  kubectl scale statefulset vaultwarden -n vaultwarden --replicas=0"
      echo "  cp $RESTORE_DIR/vaultwarden/* /var/lib/rancher/k3s/storage/<vaultwarden-pvc>/"
      echo "  kubectl scale statefulset vaultwarden -n vaultwarden --replicas=1"
      echo ""
      echo "For K8s Secrets:"
      echo "  kubectl apply -f $RESTORE_DIR/k8s-secrets/"
      echo ""
      echo "Remember to clean up: rm -rf $RESTORE_DIR"
    '')
  ];

  systemd.services.backup-setup = {
    description = "Initialize Restic backup repository";
    after = [
      "k3s-extras.target"
    ]
    ++ lib.optionals (serverConfig.storage.useNFS or false) [ "mnt-nas1.mount" ];
    wants = lib.optionals (serverConfig.storage.useNFS or false) [ "mnt-nas1.mount" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "backup-setup" ''
        set -e
        MARKER_FILE="/var/lib/backup-setup-done"

        if [ -f "$MARKER_FILE" ]; then
          echo "Backup system already initialized"
          exit 0
        fi

        echo "Initializing backup system..."

        # Create directories
        mkdir -p /var/lib/backup
        mkdir -p "${dumpDir}"

        # Generate password if not exists
        if [ ! -f "${passwordFile}" ]; then
          echo "Generating Restic password..."
          ${pkgs.openssl}/bin/openssl rand -base64 32 > "${passwordFile}"
          chmod 600 "${passwordFile}"
          echo "Password saved to ${passwordFile}"
          echo "IMPORTANT: Back up this password separately. Without it, backups cannot be restored."
        fi

        # Wait for NAS mount (try mounting if not available)
        echo "Waiting for NAS mount..."
        for i in $(seq 1 30); do
          if ${mountpoint} -q /mnt/nas1 2>/dev/null; then
            echo "NAS mounted"
            break
          fi
          # Try to trigger mount if not yet mounted
          if [ "$i" -eq 1 ] || [ "$((i % 5))" -eq 0 ]; then
            ${pkgs.util-linux}/bin/mount /mnt/nas1 2>/dev/null || true
          fi
          echo "Waiting for /mnt/nas1... ($i/30)"
          sleep 10
        done

        if ! ${mountpoint} -q /mnt/nas1 2>/dev/null; then
          echo "ERROR: NAS not mounted at /mnt/nas1, cannot initialize backup"
          exit 1
        fi

        # Create backup directory on NAS
        mkdir -p "${resticRepo}"

        # Initialize Restic repo if needed
        ${resticEnv}
        if ! ${restic} cat config &>/dev/null 2>&1; then
          echo "Initializing Restic repository..."
          ${restic} init
          echo "Restic repository initialized at ${resticRepo}"
        else
          echo "Restic repository already exists"
        fi

        # Backup Restic password to NAS (outside repo, for disaster recovery)
        RESTIC_PASSWORD_BACKUP="/mnt/nas1/backups/RESTIC_PASSWORD.txt"
        if [ ! -f "$RESTIC_PASSWORD_BACKUP" ]; then
          mkdir -p "$(dirname "$RESTIC_PASSWORD_BACKUP")"
          cp "${passwordFile}" "$RESTIC_PASSWORD_BACKUP"
          chmod 600 "$RESTIC_PASSWORD_BACKUP"
          echo "Restic password backed up to NAS"
        fi

        touch "$MARKER_FILE"
        echo "Backup system initialized"
      '';
    };
  };

  # DB dump service: dumps all PostgreSQL databases + Vaultwarden SQLite + K8s Secrets
  systemd.services.backup-db-dump = {
    description = "Dump databases for backup";
    after = [ "backup-setup.service" ];
    requires = [ "backup-setup.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = dumpScript;
    };
  };

  # Critical backup: Vaultwarden + DB dumps + K8s Secrets (daily 03:00)
  systemd.services.backup-critical = {
    description = "Critical backup (Vaultwarden + DB dumps + Secrets)";
    after = [ "backup-setup.service" ];
    requires = [ "backup-setup.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = dumpScript;
      ExecStart = pkgs.writeShellScript "backup-critical" ''
        set -e
        ${resticEnv}

        echo "=== Critical Backup ==="

        # Verify NAS is mounted
        if ! ${mountpoint} -q /mnt/nas1 2>/dev/null; then
          echo "ERROR: NAS not mounted, skipping backup"
          exit 1
        fi

        # Find Vaultwarden PVC
        VAULTWARDEN_PVC=$(ls -d ${k3sStorage}/pvc-*_vaultwarden_* 2>/dev/null | head -1)
        BACKUP_PATHS="${dumpDir}"
        if [ -n "$VAULTWARDEN_PVC" ] && [ -d "$VAULTWARDEN_PVC" ]; then
          BACKUP_PATHS="$BACKUP_PATHS $VAULTWARDEN_PVC"
        fi

        echo "Backing up: $BACKUP_PATHS"
        ${restic} backup \
          --tag critical \
          --tag daily \
          $BACKUP_PATHS

        # Cleanup sensitive dumps after backup
        rm -rf "${dumpDir}/k8s-secrets"

        echo ""
        echo "Critical backup completed"
        ${restic} snapshots --latest 3 --tag critical
      '';
    };
  };

  systemd.timers.backup-critical = {
    description = "Daily critical backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
  };

  # Full backup: all K3s PVC storage (weekly Sunday 04:00)
  systemd.services.backup-full = {
    description = "Full backup (all PVC data)";
    after = [ "backup-setup.service" ];
    requires = [ "backup-setup.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "backup-full" ''
        set -e
        ${resticEnv}

        echo "=== Full Backup ==="

        # Verify NAS is mounted
        if ! ${mountpoint} -q /mnt/nas1 2>/dev/null; then
          echo "ERROR: NAS not mounted, skipping backup"
          exit 1
        fi

        if [ ! -d "${k3sStorage}" ]; then
          echo "ERROR: K3s storage directory not found at ${k3sStorage}"
          exit 1
        fi

        echo "Backing up: ${k3sStorage}"
        echo "Excluding: media, transcodes, downloads"

        ${restic} backup \
          --tag full \
          --tag weekly \
          --exclude-file=${excludeFile} \
          ${k3sStorage} \
          ${dumpDir}

        # Cleanup sensitive dumps after backup
        rm -rf "${dumpDir}/k8s-secrets"

        echo ""
        echo "Full backup completed"
        ${restic} snapshots --latest 3 --tag full
      '';
    };
  };

  systemd.timers.backup-full = {
    description = "Weekly full backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  # Cleanup: apply retention policy (weekly Sunday 06:00)
  systemd.services.backup-cleanup = {
    description = "Backup cleanup and retention";
    after = [ "backup-setup.service" ];
    requires = [ "backup-setup.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "backup-cleanup" ''
        set -e
        ${resticEnv}

        echo "=== Backup Cleanup ==="

        # Verify NAS is mounted
        if ! ${mountpoint} -q /mnt/nas1 2>/dev/null; then
          echo "ERROR: NAS not mounted, skipping cleanup"
          exit 1
        fi

        echo "Applying retention policy..."
        ${restic} forget \
          --keep-daily 7 \
          --keep-weekly 4 \
          --keep-monthly 6 \
          --keep-yearly 1 \
          --prune

        echo ""
        echo "Checking repository integrity..."
        ${restic} check

        echo ""
        echo "Repository stats:"
        ${restic} stats --mode raw-data

        echo ""
        echo "Cleanup completed"
      '';
    };
  };

  systemd.timers.backup-cleanup = {
    description = "Weekly backup cleanup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 06:00:00";
      Persistent = true;
    };
  };
}
