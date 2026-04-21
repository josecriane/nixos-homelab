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

      release = k8s.createHelmRelease {
        inherit name;
        namespace = "media";
        tier = "apps";
        chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
        version = "4.6.1";
        valuesFile = ./arr-values.yaml;
        substitutions = {
          NAME = name;
          IMAGE_REPO = imageRepo;
          IMAGE_TAG = imageTag;
          PORT = port;
          CONFIG_PVC = configPvc;
          SECRET = apiKeySecret;
          EXTRA_PERSISTENCE = extraPersistence;
          CPU_REQ = cpuReq;
          MEM_REQ = memReq;
          MEM_LIM = memLim;
        };
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
