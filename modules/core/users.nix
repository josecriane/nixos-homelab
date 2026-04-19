{ ... }:

{
  # Upstream's modules/core/users.nix is loaded by nixos-k8s.lib.mkCluster,
  # so this file only overlays homelab-specific values on top.

  k8s.users = {
    kubectlSetenv = true;

    extraSudoCommands = [
      # Homelab uses a second marker suffix (config-done) for service config reruns.
      {
        command = "/run/current-system/sw/bin/rm -f /var/lib/*-config-done";
        options = [ "NOPASSWD" ];
      }

      {
        command = "/run/current-system/sw/bin/systemctl start mnt-*.mount";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/systemctl stop mnt-*.mount";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/systemctl restart mnt-*.mount";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/systemctl start service-scaledown.service";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/systemctl restart service-scaledown.service";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/systemctl start nfs-heal.service";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/systemctl status nfs-heal.service";
        options = [ "NOPASSWD" ];
      }

      # Backup wrappers defined by modules/kubernetes/backup/restic.nix.
      {
        command = "/run/current-system/sw/bin/backup-now";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/backup-status";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/backup-restore";
        options = [ "NOPASSWD" ];
      }
    ];
  };
}
