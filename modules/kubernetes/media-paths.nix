{
  lib,
  k8s,
  serverConfig,
}:

let
  primary = k8s.primaryNas;
  secondary =
    lib.filter
      (
        cfg:
        (cfg.enabled or false)
        && (cfg.mediaPaths or [ ]) != [ ]
        && (primary == null || cfg.ip != primary.ip)
      )
      (
        lib.mapAttrsToList (name: cfg: cfg // { hostname = cfg.hostname or name; }) (
          serverConfig.nas or { }
        )
      );

  ownerOf = rel: lib.findFirst (cfg: lib.elem rel cfg.mediaPaths) null secondary;

  mountPoint = cfg: "/data/${cfg.hostname}";
  claimName = cfg: "shared-data-${cfg.hostname}";
in
{
  inherit secondary mountPoint claimName;

  mediaPath =
    rel:
    let
      owner = ownerOf rel;
    in
    if owner == null then "/data/${rel}" else "${mountPoint owner}/${rel}";

  persistence = lib.listToAttrs (
    map (cfg: {
      name = claimName cfg;
      value = {
        type = "persistentVolumeClaim";
        existingClaim = claimName cfg;
        globalMounts = [ { path = mountPoint cfg; } ];
      };
    }) secondary
  );
}
