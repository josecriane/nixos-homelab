{
  pkgs,
  serverConfig,
  nixos-k8s,
  ...
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  ns = "media";
  markerFile = "/var/lib/media-config-pvcs-setup-done";

  pvcs = [
    {
      name = "prowlarr-config";
      size = "1Gi";
    }
    {
      name = "sonarr-config";
      size = "1Gi";
    }
    {
      name = "sonarr-es-config";
      size = "1Gi";
    }
    {
      name = "radarr-config";
      size = "1Gi";
    }
    {
      name = "radarr-es-config";
      size = "1Gi";
    }
    {
      name = "qbittorrent-config";
      size = "1Gi";
    }
    {
      name = "bazarr-config";
      size = "1Gi";
    }
    {
      name = "lidarr-config";
      size = "1Gi";
    }
    {
      name = "jellyfin-config";
      size = "5Gi";
    }
    {
      name = "jellyseerr-config";
      size = "1Gi";
    }
    {
      name = "kavita-config";
      size = "2Gi";
    }
    {
      name = "bookshelf-config";
      size = "1Gi";
    }
  ];
in
{
  systemd.services.media-config-pvcs-setup = {
    description = "Create media namespace config PVCs (default StorageClass)";
    wantedBy = [ "k3s-storage.target" ];
    before = [ "k3s-storage.target" ];
    after = [ "k3s-infrastructure.target" ];
    requires = [ "k3s-infrastructure.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "media-config-pvcs-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Media Config PVCs"

        wait_for_k3s

        $KUBECTL get namespace ${ns} &>/dev/null || $KUBECTL create namespace ${ns}

        ${builtins.concatStringsSep "\n" (map (p: ''create_pvc "${p.name}" "${ns}" "${p.size}"'') pvcs)}

        create_marker "${markerFile}"
      '';
    };
  };
}
