# Kernel crash dump (kdump) - saves vmcore to NAS via NFS on kernel panic
# After a crash, the kexec'd crash kernel boots into this system,
# detects /proc/vmcore, compresses it with zstd, saves to NAS, and reboots.
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  # Find the first enabled NAS
  enabledNas = lib.filterAttrs (name: cfg: cfg.enabled or false) (serverConfig.nas or { });
  firstNas = lib.findFirst (_: true) null (lib.attrValues enabledNas);
  hasNas = firstNas != null;

  nasIP = if hasNas then firstNas.ip else "";
  nfsExports = if hasNas then (firstNas.nfsExports or { }) else { };
  nfsPath = nfsExports.nfsPath or "/";
in
lib.mkIf hasNas {
  boot.crashDump.enable = true;
  boot.crashDump.reservedMemory = "512M";

  # Override default crash kernel params: boot into multi-user (not rescue)
  # so our kdump-save service can run with networking
  boot.crashDump.kernelParams = lib.mkForce [
    "3"
    "irqpoll"
    "nr_cpus=1"
    "reset_devices"
  ];

  environment.systemPackages = [ pkgs.zstd ];

  systemd.services.kdump-save = {
    description = "Save kernel crash dump to NAS";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "kdump-save" ''
        set -euo pipefail

        if [ ! -f /proc/vmcore ]; then
          echo "No /proc/vmcore found, normal boot. Nothing to do."
          exit 0
        fi

        echo "=== CRASH DUMP DETECTED ==="
        echo "Saving kernel crash dump to NAS..."

        TIMESTAMP=$(date +%Y%m%d-%H%M%S)
        NAS_IP="${nasIP}"
        NFS_PATH="${nfsPath}"
        MOUNT_DIR=$(mktemp -d /tmp/crashdump-nfs.XXXXXX)
        DUMP_DIR="$MOUNT_DIR/crashdumps"

        cleanup() {
          umount "$MOUNT_DIR" 2>/dev/null || true
          rmdir "$MOUNT_DIR" 2>/dev/null || true
        }
        trap cleanup EXIT

        echo "Mounting NFS: $NAS_IP:$NFS_PATH -> $MOUNT_DIR"
        mount -t nfs4 "$NAS_IP:$NFS_PATH" "$MOUNT_DIR" -o soft,timeo=30,retrans=2

        mkdir -p "$DUMP_DIR"

        # Save compressed vmcore
        echo "Compressing vmcore with zstd (this may take a few minutes)..."
        ${pkgs.zstd}/bin/zstd -1 -T0 /proc/vmcore -o "$DUMP_DIR/vmcore-$TIMESTAMP.zst"

        # Save dmesg from crashed kernel if available
        if [ -f /proc/vmcore ]; then
          dmesg > "$DUMP_DIR/dmesg-$TIMESTAMP.txt" 2>/dev/null || true
        fi

        DUMP_SIZE=$(du -sh "$DUMP_DIR/vmcore-$TIMESTAMP.zst" | cut -f1)
        echo "Crash dump saved: crashdumps/vmcore-$TIMESTAMP.zst ($DUMP_SIZE)"
        echo "Rebooting into normal kernel..."

        cleanup
        trap - EXIT
        systemctl reboot
      '';
    };
  };
}
