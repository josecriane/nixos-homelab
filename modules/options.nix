{
  config,
  lib,
  serverConfig,
  ...
}:
let
  inherit (lib) mkOption types;

  defaults = import ./homelab-defaults.nix;

  freeform =
    options:
    types.submodule {
      inherit options;
      freeformType = types.attrs;
    };

  bool =
    default:
    mkOption {
      inherit default;
      type = types.bool;
    };
in
{
  options.homelab = mkOption {
    description = "Homelab-specific configuration layered on top of nixos-k8s.";
    type = freeform {
      services = mkOption {
        default = { };
        type = freeform {
          authentik = bool defaults.services.authentik;
          vaultwarden = bool defaults.services.vaultwarden;
          nextcloud = bool defaults.services.nextcloud;
          media = bool defaults.services.media;
          immich = bool defaults.services.immich;
          syncthing = bool defaults.services.syncthing;
          dashboard = bool defaults.services.dashboard;
          kiwix = bool defaults.services.kiwix;
          openstreetmap = bool defaults.services.openstreetmap;
          switchboard = bool defaults.services.switchboard;
          paperless = bool defaults.services.paperless;
          stirling-pdf = bool defaults.services.stirling-pdf;
        };
      };

      nas = mkOption {
        default = defaults.nas;
        type = types.attrsOf (freeform {
          enabled = bool false;
        });
      };

      authentik = mkOption {
        default = { };
        type = freeform {
          ldap = mkOption {
            default = { };
            type = freeform { enable = bool defaults.authentik.ldap.enable; };
          };
          bootstrapUsers = mkOption {
            type = types.attrs;
            default = defaults.authentik.bootstrapUsers;
          };
        };
      };

      opensubtitles = mkOption {
        default = { };
        type = freeform {
          username = mkOption {
            type = types.str;
            default = defaults.opensubtitles.username;
          };
        };
      };

      backup = mkOption {
        default = { };
        type = freeform {
          localPath = mkOption {
            type = types.str;
            default = defaults.backup.localPath;
          };
          extraPaths = mkOption {
            type = types.listOf types.str;
            default = defaults.backup.extraPaths;
          };
        };
      };
    };
  };

  config = {
    homelab = serverConfig;

    assertions = [
      {
        assertion = builtins.deepSeq config.homelab true;
        message = "unreachable: homelab config failed to evaluate";
      }
    ];
  };
}
