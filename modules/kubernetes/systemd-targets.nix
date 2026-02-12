{
  config,
  lib,
  pkgs,
  ...
}:

{
  systemd.targets.k3s-infrastructure = {
    description = "K3s infrastructure services";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "k3s.service"
    ];
    wants = [
      "network-online.target"
      "k3s.service"
    ];
  };

  systemd.targets.k3s-storage = {
    description = "K3s storage services";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s-infrastructure.target" ];
    requires = [ "k3s-infrastructure.target" ];
  };

  systemd.targets.k3s-core = {
    description = "K3s core services";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s-storage.target" ];
    requires = [ "k3s-storage.target" ];
  };

  systemd.targets.k3s-media = {
    description = "K3s media services";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s-core.target" ];
    requires = [ "k3s-core.target" ];
  };

  systemd.targets.k3s-extras = {
    description = "K3s extra services (optional)";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s-media.target" ];
    wants = [ "k3s-media.target" ];
  };
}
