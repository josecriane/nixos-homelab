{
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  ...
}:

let
  adminPasswordFile = "${secretsPath}/admin-password-hash.age";
  hasAdminPassword = builtins.pathExists adminPasswordFile;
in
{
  age.secrets.admin-password-hash = lib.mkIf hasAdminPassword {
    file = adminPasswordFile;
  };

  # Agenix decrypts secrets in an activation script that by default runs AFTER
  # the users activation. hashedPasswordFile would then read a non-existent file
  # and the account gets locked with '!' in /etc/shadow. Force users to wait.
  system.activationScripts.users.deps = lib.mkIf hasAdminPassword [ "agenixInstall" ];

  # Make user management fully declarative so hashedPasswordFile is re-applied
  # on every activation (with mutableUsers=true it only applies at first create).
  users.mutableUsers = !hasAdminPassword;

  users.users.${serverConfig.adminUser} = {
    isNormalUser = true;
    description = "Server Administrator";
    extraGroups = [
      "wheel"
      "networkmanager"
      "docker"
    ];
    openssh.authorizedKeys.keys = serverConfig.adminSSHKeys;
    shell = pkgs.bash;
  }
  // lib.optionalAttrs hasAdminPassword {
    hashedPasswordFile = config.age.secrets.admin-password-hash.path;
  };

  security.sudo = {
    wheelNeedsPassword = hasAdminPassword;
    extraRules = lib.optionals hasAdminPassword [
      {
        groups = [ "wheel" ];
        commands = [
          {
            command = "/run/current-system/sw/bin/systemctl status *-setup.service";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl restart *-setup.service";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl start *-setup.service";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl stop *-setup.service";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/journalctl";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/rm -f /var/lib/*-setup-done";
            options = [ "NOPASSWD" ];
          }
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
          {
            command = "/run/current-system/sw/bin/kubectl";
            options = [
              "NOPASSWD"
              "SETENV"
            ];
          }
        ];
      }
    ];
  };

  # Disable root login
  users.users.root.hashedPassword = "!";
}
