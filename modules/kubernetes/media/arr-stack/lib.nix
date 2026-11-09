# Shared helper to build an arr-instance Helm release module.
# Each instance (prowlarr, sonarr, radarr) uses the
# bjw-s/app-template chart. Values are built as a Nix attrset and passed
# directly to k8s.helmReleases (serialized to JSON, converted to YAML at
# deploy time via yq). No template file, no token substitution.
{
  config,
  k8s,
  lib,
  pkgs,
  ...
}:

let

  puidInt = config.cluster.puid;
  pgidInt = config.cluster.pgid;
  puid = toString puidInt;
  pgid = toString pgidInt;
  timezone = config.cluster.timezone;

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
      dashboard ? null,
      widgetType ? null,
      widgetOptions ? { },
      extraAfter ? [ ],
    }:
    let
      release = {
        after = [
          "arr-secrets-setup.service"
          "nfs-storage-setup.service"
        ]
        ++ extraAfter;
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
        ingresses = [
          {
            host = ingressHost;
            service = name;
            port = port;
          }
        ];
        middlewares = k8s.forwardAuthMiddleware;
      };
    in
    {
      k8s.helmReleases.${name} = release;
      dashboard.items = lib.optionalAttrs (dashboard != null) {
        ${name} = {
          group = "downloads";
          title = dashboard.title;
          icon = dashboard.icon;
          subtitle = dashboard.subtitle;
          url = "https://${k8s.hostname ingressHost}";
          sort = dashboard.sort or 100;
          workload = {
            namespace = "media";
            inherit name;
          };
          widget =
            if widgetType == null then
              null
            else
              {
                type = widgetType;
                url = "http://${name}.media.svc.cluster.local:${toString port}";
                secrets.key = {
                  namespace = "media";
                  secret = apiKeySecret;
                  key = "api-key";
                };
                options = widgetOptions;
              };
        };
      };
    };
in
{
  inherit mkArrRelease;
}
