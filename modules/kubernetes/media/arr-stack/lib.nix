# Shared helper to build an arr-instance Helm release module.
# Each instance (prowlarr, sonarr, radarr, sonarr-es, radarr-es) uses the
# bjw-s/app-template chart with arr-values.yaml and token substitution.
{
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };
  puid = toString (serverConfig.puid or 1000);
  pgid = toString (serverConfig.pgid or 1000);

  mkArrRelease =
    {
      name,
      imageRepo,
      imageTag,
      port,
      configPvc,
      apiKeySecret,
      ingressHost ? name,
      withSharedData ? true,
      cpuReq ? "50m",
      memReq ? "128Mi",
      memLim ? "512Mi",
      extraAfter ? [ ],
    }:
    let
      extraPersistence =
        if withSharedData then
          ''
            data:
              type: persistentVolumeClaim
              existingClaim: shared-data
              advancedMounts:
                ${name}:
                  main:
                    - path: /data''
        else
          "";

      values = pkgs.writeText "${name}-values.yaml" (
        builtins.replaceStrings
          [
            "__NAME__"
            "__IMAGE_REPO__"
            "__IMAGE_TAG__"
            "__PORT__"
            "__CONFIG_PVC__"
            "__SECRET__"
            "__EXTRA_PERSISTENCE__"
            "__CPU_REQ__"
            "__MEM_REQ__"
            "__MEM_LIM__"
            "__TIMEZONE__"
            "__PUID__"
            "__PGID__"
          ]
          [
            name
            imageRepo
            imageTag
            (toString port)
            configPvc
            apiKeySecret
            extraPersistence
            cpuReq
            memReq
            memLim
            serverConfig.timezone
            puid
            pgid
          ]
          (builtins.readFile ./arr-values.yaml)
      );

      release = k8s.createHelmRelease {
        inherit name;
        namespace = "media";
        tier = "apps";
        chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
        version = "4.6.1";
        valuesFile = values;
        waitFor = name;
        ingress = {
          host = ingressHost;
          service = name;
          port = port;
        };
        middlewares = k8s.forwardAuthMiddleware;
      };
    in
    lib.recursiveUpdate release {
      systemd.services."${name}-setup" = {
        after =
          (release.systemd.services."${name}-setup".after or [ ])
          ++ [
            "arr-secrets-setup.service"
            "nfs-storage-setup.service"
          ]
          ++ extraAfter;
        wants = [
          "arr-secrets-setup.service"
          "nfs-storage-setup.service"
        ]
        ++ extraAfter;
      };
    };
in
{
  inherit mkArrRelease;
}
