# Backup system using Restic + systemd timers
# Repository lives on the NAS when storage.useNFS is set, otherwise on the node
# Tiers: Critical (daily 03:00), Full (weekly Sun 04:00), Cleanup (weekly Sun 06:00)
{
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  ...
}:

let
  kubectl = "${pkgs.kubectl}/bin/kubectl";
  restic = "${pkgs.restic}/bin/restic";
  gzip = "${pkgs.gzip}/bin/gzip";
  gunzip = "${pkgs.gzip}/bin/gunzip";
  jq = "${pkgs.jq}/bin/jq";
  sqlite = "${pkgs.sqlite}/bin/sqlite3";
  mountpoint = "${pkgs.util-linux}/bin/mountpoint";
  findmnt = "${pkgs.util-linux}/bin/findmnt";
  mount = "${pkgs.util-linux}/bin/mount";
  umount = "${pkgs.util-linux}/bin/umount";
  timeout = "${pkgs.coreutils}/bin/timeout";

  useNFS = serverConfig.storage.useNFS or false;

  nasMountPoint = "/mnt/nas1";
  backupDir =
    if useNFS then
      "${nasMountPoint}/backups"
    else
      (serverConfig.backup.localPath or "/var/lib/backup/repo");

  # Backup paths
  resticRepo = "${backupDir}/restic-repo";
  passwordFile = config.age.secrets.restic-password.path;
  dumpDir = "/var/lib/backup/db-dumps";
  repoIdFile = "/var/lib/backup/repo-id";
  k3sStorage = "/var/lib/rancher/k3s/storage";

  stageDir = "/run/backup-volumes";

  extraPaths = serverConfig.backup.extraPaths or [ ];

  backupDirIsBind =
    useNFS
    && lib.any (cfg: (cfg.enabled or false) && lib.elem "backups" (cfg.mediaPaths or [ ])) (
      lib.attrValues (serverConfig.nas or { })
    );

  mountUnits = lib.optionals useNFS (
    [ "mnt-nas1.mount" ] ++ lib.optional backupDirIsBind "mnt-nas1-backups.mount"
  );

  nasGuard = lib.optionalString useNFS ''
    if ! ${mountpoint} -q ${nasMountPoint} 2>/dev/null; then
      echo "ERROR: ${nasMountPoint} not mounted, aborting"
      exit 1
    fi
    ${lib.optionalString backupDirIsBind ''
      if ! ${mountpoint} -q ${backupDir} 2>/dev/null; then
        echo "ERROR: ${backupDir} is not a mount point."
        echo "The NAS bind mount is missing; writing here would target the wrong disk."
        exit 1
      fi
    ''}
  '';

  # Restic env
  resticEnv = ''
    export RESTIC_REPOSITORY="${resticRepo}"
    export RESTIC_PASSWORD_FILE="${passwordFile}"
  '';

  cacheDir = "/var/cache/restic";
  resticServiceEnv = ''
    ${resticEnv}
    export RESTIC_CACHE_DIR="${cacheDir}"
  '';

  cacheServiceConfig = {
    CacheDirectory = "restic";
    CacheDirectoryMode = "0700";
  };

  repoGuard = ''
    ${nasGuard}

    if ! REPO_CONFIG=$(${timeout} 60 ${restic} cat config 2>&1); then
      echo "ERROR: cannot open restic repository at ${resticRepo}:"
      echo "$REPO_CONFIG" | sed 's/^/  /'
      exit 1
    fi

    REPO_ID=$(printf '%s' "$REPO_CONFIG" | ${jq} -r '.id // empty')
    if [ -z "$REPO_ID" ]; then
      echo "ERROR: restic repository config carries no id"
      exit 1
    fi

    if [ -f "${repoIdFile}" ]; then
      EXPECTED_REPO_ID=$(cat "${repoIdFile}")
      if [ "$REPO_ID" != "$EXPECTED_REPO_ID" ]; then
        echo "ERROR: repository at ${resticRepo} is $REPO_ID, expected $EXPECTED_REPO_ID."
        echo "The backup path most likely resolves to a different disk. Refusing to continue."
        echo "If this change is intentional, update ${repoIdFile}."
        exit 1
      fi
    else
      printf '%s\n' "$REPO_ID" > "${repoIdFile}"
      echo "Pinned repository id $REPO_ID"
    fi
  '';

  pvcHostPathFn = ''
    pvc_host_path() {
      local ns="$1" pvc="$2" pv targets dir
      pv=$(${kubectl} get pvc -n "$ns" "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
      [ -n "$pv" ] || return 1

      if [ -b "/dev/longhorn/$pv" ]; then
        targets=$(${findmnt} -n -o TARGET "/dev/longhorn/$pv" 2>/dev/null || true)
        [ -n "$targets" ] || return 1
        local first="" t
        for t in $targets; do
          [ -n "$first" ] || first="$t"
          case "$t" in
            *globalmount*)
              printf '%s\n' "$t"
              return 0
              ;;
          esac
        done
        printf '%s\n' "$first"
        return 0
      fi

      dir="${k3sStorage}/''${pv}_''${ns}_''${pvc}"
      if [ -d "$dir" ]; then
        printf '%s\n' "$dir"
        return 0
      fi

      return 1
    }
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
    "*immich*/thumbs/*"
    "*immich*/encoded-video/*"
    "*.tmp"
    "*.log"
  ];

  excludeFile = pkgs.writeText "backup-excludes" (builtins.concatStringsSep "\n" excludePatterns);

  skipVolumes = [
    "immich/immich-ml-cache"
    "monitoring/prometheus-"
    "monitoring/alertmanager-"
  ];

  skipVolumesCase = builtins.concatStringsSep "|" (map (v: "${v}*") skipVolumes);

  nodeStorageClasses = [
    "longhorn"
    "local-path"
  ];

  nodeStorageClassesCase = builtins.concatStringsSep "|" nodeStorageClasses;

  # Shared dump script (used by backup-db-dump, backup-critical and backup-full)
  dumpScript = pkgs.writeShellScript "backup-db-dump" ''
    set -euo pipefail
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    ${pvcHostPathFn}

    FAILED=0

    echo "=== Database Dumps ==="
    install -d -m 0700 /var/lib/backup
    install -d -m 0700 "${dumpDir}"
    install -d -m 0700 "${dumpDir}/k8s-secrets"

    # PostgreSQL dumps
    ${builtins.concatStringsSep "\n" (
      map (
        pg:
        let
          execTarget = if pg ? deploy then "deploy/${pg.deploy}" else pg.pod;
          getTarget = if pg ? deploy then "deploy/${pg.deploy}" else "pod/${pg.pod}";
        in
        ''
          echo "Dumping ${pg.db} (${pg.ns})..."
          if ${kubectl} get ${getTarget} -n ${pg.ns} >/dev/null 2>&1; then
            DUMP_ERR=$(mktemp)
            DUMP_TMP="${dumpDir}/${pg.db}.sql.gz.tmp"
            set +e
            ${kubectl} exec -n ${pg.ns} ${execTarget} -- \
              sh -c 'export PGPASSWORD="''${POSTGRES_PASSWORD:-$(cat "''${POSTGRES_PASSWORD_FILE:-/dev/null}" 2>/dev/null)}"; exec pg_dump -U ${pg.user} -d ${pg.db}' \
              2>"$DUMP_ERR" | ${gzip} > "$DUMP_TMP"
            DUMP_RC=''${PIPESTATUS[0]}
            set -e

            set +o pipefail
            DUMP_HEAD=$(${gunzip} -c "$DUMP_TMP" 2>/dev/null | head -c 512)
            set -o pipefail

            case "$DUMP_HEAD" in
              *"PostgreSQL database dump"*) DUMP_VALID=1 ;;
              *) DUMP_VALID=0 ;;
            esac

            if [ "$DUMP_RC" -ne 0 ]; then
              echo "  ERROR: pg_dump for ${pg.db} exited $DUMP_RC:"
              sed 's/^/    /' "$DUMP_ERR"
              rm -f "$DUMP_TMP"
              FAILED=$((FAILED + 1))
            elif [ "$DUMP_VALID" -eq 0 ]; then
              echo "  ERROR: dump for ${pg.db} is empty or truncated, keeping previous copy"
              sed 's/^/    /' "$DUMP_ERR"
              rm -f "$DUMP_TMP"
              FAILED=$((FAILED + 1))
            else
              mv "$DUMP_TMP" "${dumpDir}/${pg.db}.sql.gz"
              chmod 0600 "${dumpDir}/${pg.db}.sql.gz"
              echo "  ${pg.db}: $(du -h "${dumpDir}/${pg.db}.sql.gz" | cut -f1)"
            fi
            rm -f "$DUMP_ERR"
          else
            echo "  ${execTarget} not present in ${pg.ns}, skipping"
          fi
        ''
      ) pgDumps
    )}

    # Vaultwarden SQLite backup
    echo "Backing up Vaultwarden..."
    if ${kubectl} get pvc -n vaultwarden vaultwarden-data-vaultwarden-0 >/dev/null 2>&1; then
      VW_DIR=$(pvc_host_path vaultwarden vaultwarden-data-vaultwarden-0 || true)
      if [ -n "$VW_DIR" ] && [ -f "$VW_DIR/db.sqlite3" ]; then
        rm -rf "${dumpDir}/vaultwarden"
        install -d -m 0700 "${dumpDir}/vaultwarden"
        ${sqlite} "$VW_DIR/db.sqlite3" ".backup '${dumpDir}/vaultwarden/db.sqlite3'"
        for EXTRA in rsa_key.pem rsa_key.pub.pem config.json; do
          if [ -f "$VW_DIR/$EXTRA" ]; then
            cp "$VW_DIR/$EXTRA" "${dumpDir}/vaultwarden/"
          fi
        done
        for EXTRA in attachments sends; do
          if [ -d "$VW_DIR/$EXTRA" ]; then
            cp -r "$VW_DIR/$EXTRA" "${dumpDir}/vaultwarden/"
          fi
        done
        chmod -R go-rwx "${dumpDir}/vaultwarden"
        echo "  Vaultwarden: $(du -sh "${dumpDir}/vaultwarden" | cut -f1) (from $VW_DIR)"
      else
        echo "  ERROR: Vaultwarden volume not readable on this node, nothing backed up"
        FAILED=$((FAILED + 1))
      fi
    else
      echo "  vaultwarden PVC not present, skipping"
    fi

    # K8s Secrets backup (all namespaces)
    echo "Backing up K8s Secrets..."
    for NS in $(${kubectl} get namespace -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
      if ! ${kubectl} get secrets -n "$NS" -o yaml > "${dumpDir}/k8s-secrets/$NS-secrets.yaml"; then
        echo "  ERROR: could not dump secrets for $NS"
        rm -f "${dumpDir}/k8s-secrets/$NS-secrets.yaml"
        FAILED=$((FAILED + 1))
      fi
    done

    # Credential secrets backup (all namespaces, labeled)
    ${kubectl} get secrets --all-namespaces -l k8s/credential=true -o yaml \
      > "${dumpDir}/k8s-secrets/all-credentials.yaml"
    chmod -R go-rwx "${dumpDir}/k8s-secrets"
    echo "  K8s Secrets: $(du -sh "${dumpDir}/k8s-secrets" | cut -f1)"

    echo ""
    if [ "$FAILED" -gt 0 ]; then
      echo "Dumps completed with $FAILED failure(s): $(du -sh "${dumpDir}" | cut -f1) total"
      exit 1
    fi
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

      echo "Repository location: ${resticRepo}"
      ${
        if useNFS then
          ''
            if ${mountpoint} -q ${nasMountPoint} 2>/dev/null; then
              echo "NAS mount: OK (${nasMountPoint})"
            else
              echo "NAS mount: NOT MOUNTED"
            fi
            ${lib.optionalString backupDirIsBind ''
              if ${mountpoint} -q ${backupDir} 2>/dev/null; then
                echo "Backup mount: OK (${backupDir})"
              else
                echo "Backup mount: NOT MOUNTED (${backupDir}) - backups will refuse to run"
              fi
            ''}
          ''
        else
          ''echo "Storage: local (no NAS configured)"''
      }

      # Check repo
      if [ -d "${resticRepo}" ]; then
        echo "Restic repo: exists"
        if [ -f "${repoIdFile}" ]; then
          echo "Pinned repo id: $(cat "${repoIdFile}")"
        fi
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
          echo "Running critical backup..."
          sudo systemctl start backup-critical.service
          ;;
        2)
          echo "Running full backup..."
          sudo systemctl start backup-full.service
          ;;
        3)
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
      echo "For Vaultwarden (SQLite), with VW the claim's directory on the node"
      echo "(CSI: findmnt /dev/<driver>/<pv>; local-path: ${k3sStorage}/<pv>_vaultwarden_*):"
      echo "  kubectl scale statefulset vaultwarden -n vaultwarden --replicas=0"
      echo "  rm -f \$VW/db.sqlite3-wal \$VW/db.sqlite3-shm"
      echo "  cp -r $RESTORE_DIR/db-dumps/vaultwarden/* \$VW/"
      echo "  kubectl scale statefulset vaultwarden -n vaultwarden --replicas=1"
      echo ""
      echo "For full-backup volumes, files sit under $RESTORE_DIR/backup-volumes/<namespace>/<pvc>/"
      echo ""
      echo "For K8s Secrets:"
      echo "  kubectl apply -f $RESTORE_DIR/db-dumps/k8s-secrets/"
      echo ""
      echo "Remember to clean up: rm -rf $RESTORE_DIR"
    '')
  ];

  age.secrets.restic-password = {
    file = "${secretsPath}/restic-password.age";
  };

  systemd.services.backup-setup = {
    description = "Initialize Restic backup repository";
    after = [ "k3s-extras.target" ] ++ mountUnits;
    wants = mountUnits;
    wantedBy = [ "multi-user.target" ];

    serviceConfig = cacheServiceConfig // {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "backup-setup" ''
        set -euo pipefail
        MARKER_FILE="/var/lib/backup-setup-done"

        if [ -f "$MARKER_FILE" ]; then
          echo "Backup system already initialized"
          exit 0
        fi

        echo "Initializing backup system..."

        # Create directories
        install -d -m 0700 /var/lib/backup
        install -d -m 0700 "${dumpDir}"

        ${lib.optionalString useNFS ''
          # Wait for NAS mount (try mounting if not available)
          echo "Waiting for NAS mount..."
          for i in $(seq 1 30); do
            if ${mountpoint} -q ${nasMountPoint} 2>/dev/null; then
              echo "NAS mounted"
              break
            fi
            # Try to trigger mount if not yet mounted
            if [ "$i" -eq 1 ] || [ "$((i % 5))" -eq 0 ]; then
              ${mount} ${nasMountPoint} 2>/dev/null || true
            fi
            echo "Waiting for ${nasMountPoint}... ($i/30)"
            sleep 10
          done

          if ! ${mountpoint} -q ${nasMountPoint} 2>/dev/null; then
            echo "ERROR: NAS not mounted at ${nasMountPoint}, cannot initialize backup"
            exit 1
          fi
        ''}
        ${lib.optionalString backupDirIsBind ''
          for i in $(seq 1 30); do
            if ${mountpoint} -q ${backupDir} 2>/dev/null; then
              break
            fi
            if [ "$i" -eq 1 ] || [ "$((i % 5))" -eq 0 ]; then
              ${mount} ${backupDir} 2>/dev/null || true
            fi
            echo "Waiting for ${backupDir}... ($i/30)"
            sleep 10
          done

          if ! ${mountpoint} -q ${backupDir} 2>/dev/null; then
            echo "ERROR: ${backupDir} is not mounted. Without the NAS bind mount this"
            echo "path resolves to a different disk, so we will not touch it."
            exit 1
          fi
        ''}

        ${resticServiceEnv}

        # Initialize Restic repo if needed
        if ${timeout} 60 ${restic} cat config >/dev/null 2>&1; then
          echo "Restic repository already exists"
        elif ${timeout} 10 test -e "${resticRepo}/config"; then
          echo "ERROR: ${resticRepo} holds a repository we cannot open."
          echo "Check that ${backupDir} is the intended disk and that the"
          echo "restic-password secret matches this repository. Not touching it."
          exit 1
        else
          echo "Initializing Restic repository..."
          mkdir -p "${resticRepo}"
          if ! ${timeout} 120 ${restic} init; then
            echo "WARN: restic init failed (NAS issue?), skipping marker creation"
            exit 1
          fi
          echo "Restic repository initialized at ${resticRepo}"
        fi

        REPO_ID=$(${timeout} 60 ${restic} cat config | ${jq} -r '.id // empty')
        if [ -z "$REPO_ID" ]; then
          echo "ERROR: could not read repository id"
          exit 1
        fi
        if [ ! -f "${repoIdFile}" ]; then
          printf '%s\n' "$REPO_ID" > "${repoIdFile}"
          echo "Pinned repository id $REPO_ID"
        elif [ "$REPO_ID" != "$(cat "${repoIdFile}")" ]; then
          echo "ERROR: repository id $REPO_ID does not match pinned $(cat "${repoIdFile}")"
          exit 1
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
    after = [ "backup-setup.service" ] ++ mountUnits;
    requires = [ "backup-setup.service" ];
    wants = mountUnits;

    serviceConfig = cacheServiceConfig // {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "backup-critical" ''
        set -euo pipefail
        ${resticServiceEnv}

        echo "=== Critical Backup ==="
        ${repoGuard}

        DUMP_RC=0
        ${dumpScript} || DUMP_RC=$?

        echo ""
        echo "Backing up: ${dumpDir}"
        ${restic} backup \
          --tag critical \
          --tag daily \
          ${dumpDir}

        # Cleanup sensitive dumps after backup
        rm -rf "${dumpDir}/k8s-secrets"

        echo ""
        echo "Critical backup completed"
        ${restic} snapshots --latest 3 --tag critical

        if [ "$DUMP_RC" -ne 0 ]; then
          echo ""
          echo "ERROR: the snapshot was taken, but some dumps failed (see above)."
          exit 1
        fi
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

  # Full backup: all node-local PVC data (weekly Sunday 04:00)
  systemd.services.backup-full = {
    description = "Full backup (all PVC data)";
    after = [ "backup-setup.service" ] ++ mountUnits;
    requires = [ "backup-setup.service" ];
    wants = mountUnits;

    serviceConfig = cacheServiceConfig // {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "backup-full" ''
        set -euo pipefail
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        ${resticServiceEnv}
        ${pvcHostPathFn}

        echo "=== Full Backup ==="
        ${repoGuard}

        cleanup_stage() {
          local mounts M
          mounts=$(${findmnt} -rn -o TARGET 2>/dev/null | sort -r || true)
          while read -r M; do
            [ -n "$M" ] || continue
            case "$M" in
              ${stageDir}/*) ${umount} "$M" 2>/dev/null || true ;;
            esac
          done <<< "$mounts"
          find "${stageDir}" -depth -type d -empty -delete 2>/dev/null || true
        }
        trap cleanup_stage EXIT
        trap 'cleanup_stage; exit 1' INT TERM
        cleanup_stage
        mkdir -p "${stageDir}"

        DUMP_RC=0
        ${dumpScript} || DUMP_RC=$?

        echo ""
        echo "Staging node-local volumes readable on this node..."
        PVC_LIST=$(${kubectl} get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.storageClassName}{"\n"}{end}')
        CANDIDATES=0
        STAGED=0
        MISSING=""

        while read -r NS PVC SC; do
          [ -n "''${NS:-}" ] || continue
          case "''${SC:-}" in
            ${nodeStorageClassesCase}) ;;
            *) continue ;;
          esac

          case "$NS/$PVC" in
            ${skipVolumesCase})
              echo "  skip (excluded by policy): $NS/$PVC"
              continue
              ;;
          esac

          CANDIDATES=$((CANDIDATES + 1))

          SRC=$(pvc_host_path "$NS" "$PVC" || true)
          if [ -z "$SRC" ]; then
            MISSING="$MISSING $NS/$PVC"
            continue
          fi

          DEST="${stageDir}/$NS/$PVC"
          mkdir -p "$DEST"
          ${mount} --bind "$SRC" "$DEST"
          ${mount} -o remount,bind,ro "$DEST"
          STAGED=$((STAGED + 1))
          echo "  staged $NS/$PVC"
        done <<< "$PVC_LIST"

        if [ -n "$MISSING" ]; then
          echo ""
          echo "NOT backed up (volume detached, or attached to another node):"
          for V in $MISSING; do echo "  $V"; done
        fi

        if [ "$STAGED" -eq 0 ] && [ "$CANDIDATES" -gt 0 ]; then
          echo "ERROR: none of the $CANDIDATES node-local volume(s) could be staged,"
          echo "refusing to take a full backup that silently contains no volume data"
          exit 1
        fi

        EXTRA_PATHS=""
        EXTRA_MISSING=0
        ${lib.optionalString (extraPaths != [ ]) ''
          echo ""
          echo "Extra paths..."
          for P in ${lib.escapeShellArgs extraPaths}; do
            if [ -d "$P" ]; then
              EXTRA_PATHS="$EXTRA_PATHS $P"
              echo "  including $P"
            else
              echo "  ERROR: configured extra path is missing: $P"
              EXTRA_MISSING=1
            fi
          done
        ''}

        echo ""
        echo "Backing up $STAGED volume(s) plus ${dumpDir}$EXTRA_PATHS"
        echo "Excluding: media, transcodes, downloads, immich derivatives"

        ${restic} backup \
          --tag full \
          --tag weekly \
          --exclude-file=${excludeFile} \
          "${stageDir}" \
          ${dumpDir} \
          $EXTRA_PATHS

        # Cleanup sensitive dumps after backup
        rm -rf "${dumpDir}/k8s-secrets"

        echo ""
        echo "Full backup completed"
        ${restic} snapshots --latest 3 --tag full

        if [ "$EXTRA_MISSING" -ne 0 ]; then
          echo ""
          echo "ERROR: some configured extra paths were missing (see above)."
          exit 1
        fi

        if [ "$DUMP_RC" -ne 0 ]; then
          echo ""
          echo "ERROR: the snapshot was taken, but some dumps failed (see above)."
          exit 1
        fi
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
    after = [ "backup-setup.service" ] ++ mountUnits;
    requires = [ "backup-setup.service" ];
    wants = mountUnits;

    serviceConfig = cacheServiceConfig // {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "backup-cleanup" ''
        set -euo pipefail
        ${resticServiceEnv}

        echo "=== Backup Cleanup ==="
        ${repoGuard}

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
