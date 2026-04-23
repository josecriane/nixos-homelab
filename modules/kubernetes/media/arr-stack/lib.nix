# Shared helper to build an arr-instance Helm release module.
# Each instance (prowlarr, sonarr, radarr, sonarr-es, radarr-es) uses the
# bjw-s/app-template chart. Values are built as a Nix attrset and passed
# directly to createHelmRelease (serialized to JSON, converted to YAML at
# deploy time via yq). No template file, no token substitution.
{
  lib,
  pkgs,
  serverConfig,
  nixos-k8s,
}:

let
  k8s = import "${nixos-k8s}/modules/kubernetes/lib.nix" { inherit pkgs serverConfig; };

  puidInt = serverConfig.puid or 1000;
  pgidInt = serverConfig.pgid or 1000;
  puid = toString puidInt;
  pgid = toString pgidInt;
  timezone = serverConfig.timezone or "UTC";

  initApiKeyScriptRaw = builtins.readFile ./init-api-key.sh;
  initApiKeyScript =
    builtins.replaceStrings [ "__PUID__" "__PGID__" ] [ puid pgid ]
      initApiKeyScriptRaw;

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
      release = k8s.createHelmRelease {
        inherit name;
        namespace = "media";
        tier = "apps";
        chart = "oci://ghcr.io/bjw-s-labs/helm/app-template";
        version = "4.6.1";
        values = {
          defaultPodOptions = {
            automountServiceAccountToken = false;
            securityContext = {
              runAsNonRoot = false;
              runAsUser = 0;
              runAsGroup = 0;
              fsGroup = pgidInt;
              fsGroupChangePolicy = "OnRootMismatch";
            };
          };
          controllers.${name} = {
            strategy = "Recreate";
            initContainers.init-api-key = {
              image = {
                repository = "busybox";
                tag = "1.37.0";
              };
              command = [
                "sh"
                "-c"
              ];
              args = [ initApiKeyScript ];
            };
            containers.main = {
              image = {
                repository = imageRepo;
                tag = imageTag;
              };
              env = {
                PUID = puid;
                PGID = pgid;
                TZ = timezone;
              };
              resources = {
                requests = {
                  cpu = cpuReq;
                  memory = memReq;
                };
                limits.memory = memLim;
              };
            };
          };
          service.${name} = {
            controller = name;
            ports.http = {
              port = port;
              targetPort = port;
            };
          };
          persistence = {
            config = {
              type = "persistentVolumeClaim";
              existingClaim = configPvc;
              globalMounts = [ { path = "/config"; } ];
            };
            api-key-secret = {
              type = "secret";
              name = apiKeySecret;
              advancedMounts.${name}.init-api-key = [
                {
                  path = "/secrets";
                  readOnly = true;
                }
              ];
            };
          }
          // lib.optionalAttrs withSharedData {
            data = {
              type = "persistentVolumeClaim";
              existingClaim = "shared-data";
              advancedMounts.${name}.main = [ { path = "/data"; } ];
            };
          };
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
