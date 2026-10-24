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

      vaultwarden = mkOption {
        default = { };
        type = freeform {
          sync = mkOption {
            default = { };
            type = freeform {
              enable = bool defaults.vaultwarden.sync.enable;
              extraServices = mkOption {
                default = [ ];
                type = types.listOf (
                  types.submodule {
                    options = {
                      name = mkOption { type = types.str; };
                      namespace = mkOption { type = types.str; };
                      secret = mkOption { type = types.str; };
                      userKey = mkOption {
                        type = types.str;
                        default = "";
                      };
                      passwordKey = mkOption {
                        type = types.str;
                        default = "";
                      };
                      urlKey = mkOption {
                        type = types.str;
                        default = "";
                      };
                      noteKeys = mkOption {
                        type = types.listOf types.str;
                        default = [ ];
                      };
                      unit = mkOption {
                        type = types.str;
                        default = "";
                      };
                    };
                  }
                );
              };
            };
          };
        };
      };

      authentik = mkOption {
        default = { };
        type = freeform {
          ldap = mkOption {
            default = { };
            type = freeform { enable = bool defaults.authentik.ldap.enable; };
          };
          google = mkOption {
            default = { };
            type = freeform {
              enable = bool defaults.authentik.google.enable;
              clientId = mkOption {
                type = types.str;
                default = defaults.authentik.google.clientId;
              };
              allowEnrollment = bool defaults.authentik.google.allowEnrollment;
            };
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
