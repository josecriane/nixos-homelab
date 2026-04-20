{
  lib,
  serverConfig,
  ...
}:

# Homelab setter: parameterizes upstream's k8s.storage.nfs to serve media
# services with the TRaSH Guides layout. Cloud PVs (nextcloud/immich) live in
# nfs-storage-cloud.nix. NAS mounts + nfs-heal come from upstream nfs-mounts.

let
  enabledNas = lib.filterAttrs (_: cfg: cfg.enabled or false) (serverConfig.nas or { });
  mediaNas = lib.findFirst (
    cfg: (cfg.role or "all") == "media" || (cfg.role or "all") == "all"
  ) null (lib.attrValues enabledNas);

  secondaryNasList = lib.filter (
    cfg: (cfg.enabled or false) && (cfg.mediaPaths or [ ]) != [ ] && cfg != mediaNas
  ) (lib.attrValues (serverConfig.nas or { }));

  nasMountPoint = "/mnt/nas1";
  pathToMountUnit =
    path: (builtins.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" path)) + ".mount";

  extraMountUnits = lib.concatMap (
    nasCfg:
    [ (pathToMountUnit "/mnt/${nasCfg.hostname}") ]
    ++ map (path: pathToMountUnit "${nasMountPoint}/${path}") nasCfg.mediaPaths
  ) secondaryNasList;
in
{
  k8s.storage.nfs = {
    namespace = "media";
    pvcName = "shared-data";
    localDataPath = "/var/lib/media-data";

    # TRaSH Guides layout.
    directoryLayout = [
      "torrents/movies"
      "torrents/tv"
      "torrents/music"
      "torrents/books"
      "torrents/incomplete"
      "media/movies"
      "media/movies-es"
      "media/tv"
      "media/tv-es"
      "media/music"
      "media/books"
      "backups"
    ];

    inherit extraMountUnits;
  };
}
