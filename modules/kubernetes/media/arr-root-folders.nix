{
  k8s,
  lib,
  pkgs,
  ...
}:

let
  arr = import ./arr-lib.nix { inherit lib; };
  markerFile = "/var/lib/arr-root-folders-setup-done";

  folders = [
    {
      app = "sonarr";
      path = "/data/media/tv";
    }
    {
      app = "radarr";
      path = "/data/media/movies";
    }
    {
      app = "lidarr";
      path = "/data/media/music";
      extra = {
        name = "Music";
        defaultMetadataProfileId = 1;
        defaultQualityProfileId = 3;
      };
    }
    {
      app = "sonarr-es";
      path = "/data/media/tv-es";
    }
    {
      app = "radarr-es";
      path = "/data/media/movies-es";
    }
    {
      app = "bookshelf";
      path = "/data/media/books";
      extra = {
        name = "Books";
        defaultQualityProfileId = 1;
        defaultMetadataProfileId = 1;
      };
    }
  ];

  ensureFolder =
    folder:
    let
      payload = builtins.toJSON ({ path = folder.path; } // (folder.extra or { }));
      match = ''.[] | select(.path == "${folder.path}")'';
    in
    "arr_ensure ${folder.app} rootfolder ${lib.escapeShellArg payload} ${lib.escapeShellArg match} ${lib.escapeShellArg folder.path}";
in
{
  systemd.services.arr-root-folders-setup = {
    description = "Configure root folders for arr-stack services";
    after = [
      "k3s-apps.target"
      "arr-credentials-setup.service"
    ];
    requires = [ "k3s-apps.target" ];
    wants = [ "arr-credentials-setup.service" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "arr-root-folders-setup" ''
        ${k8s.libShSource}
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        set +e

        setup_preamble "${markerFile}" "Root folders"
        wait_for_k3s

        ${arr.helpers}

        echo "Configuring root folders..."
        ${lib.concatMapStringsSep "\n        " ensureFolder folders}

        echo ""
        echo "=== Root folders configured ==="

        create_marker "${markerFile}"
      '';
    };
  };
}
