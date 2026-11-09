{ lib, ... }:
let
  inherit (lib) mkOption types;

  freeform =
    options:
    types.submodule {
      inherit options;
      freeformType = types.attrs;
    };

  bool =
    default: description:
    mkOption {
      inherit default description;
      type = types.bool;
    };

  str =
    default: description:
    mkOption {
      inherit default description;
      type = types.str;
    };
in
{
  options.cluster = mkOption {
    type = types.submodule {
      options = {
        services = mkOption {
          type = types.submodule {
            options = {
              authentik = bool false "Authentik identity provider, forward auth and SSO.";
              vaultwarden = bool false "Vaultwarden password manager.";
              nextcloud = bool false "Nextcloud.";
              media = bool false "Jellyfin, Jellyseerr and the *arr stack.";
              immich = bool false "Immich photo library.";
              syncthing = bool false "Syncthing.";
              dashboard = bool false "Homer dashboard.";
              kiwix = bool false "Kiwix offline wikis.";
              openstreetmap = bool false "OpenStreetMap tile server.";
              switchboard = bool false "Switchboard.";
              paperless = bool false "Paperless-ngx.";
              stirling-pdf = bool false "Stirling PDF.";
            };
          };
        };

        vaultwarden = mkOption {
          default = { };
          description = "Vaultwarden.";
          type = freeform {
            sync = mkOption {
              default = { };
              description = "Sync of service credentials into Vaultwarden.";
              type = freeform {
                enable = bool true "Whether to sync service credentials into Vaultwarden.";
                extraServices = mkOption {
                  default = [ ];
                  description = "Extra Secrets to sync into Vaultwarden.";
                  type = types.listOf (
                    types.submodule {
                      options = {
                        name = mkOption {
                          type = types.str;
                          description = "Vaultwarden item name.";
                        };
                        namespace = mkOption {
                          type = types.str;
                          description = "Namespace of the Secret.";
                        };
                        secret = mkOption {
                          type = types.str;
                          description = "Name of the Secret.";
                        };
                        userKey = str "" "Secret key of the user name.";
                        passwordKey = str "" "Secret key of the password.";
                        urlKey = str "" "Secret key of the URL.";
                        noteKeys = mkOption {
                          type = types.listOf types.str;
                          default = [ ];
                          description = "Secret keys copied into the item notes.";
                        };
                        unit = str "" "systemd unit that creates the Secret.";
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
          description = "Authentik, used when `services.authentik = true`.";
          type = freeform {
            ldap = mkOption {
              default = { };
              description = "Authentik LDAP outpost.";
              type = freeform {
                enable = bool false "Whether to deploy the LDAP outpost.";
              };
            };
            google = mkOption {
              default = { };
              description = "Google login source.";
              type = freeform {
                enable = bool false "Whether to add Google as a login source.";
                clientId = str "" "Google OAuth client ID.";
                allowEnrollment = bool false "Whether Google logins may create users.";
              };
            };
            bootstrapUsers = mkOption {
              type = types.attrs;
              default = { };
              description = "Users created at bootstrap, keyed by user name.";
            };
          };
        };

        qbittorrent = mkOption {
          type = types.attrs;
          default = { };
          description = "qBittorrent queue and ratio settings.";
        };

        opensubtitles = mkOption {
          default = { };
          description = "OpenSubtitles account for Bazarr.";
          type = freeform {
            username = str "" "OpenSubtitles user name.";
          };
        };

        backup = mkOption {
          default = { };
          description = "restic backup.";
          type = freeform {
            localPath = str "/var/lib/backup/repo" "Local restic repository.";
            extraPaths = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Extra host paths to back up.";
            };
          };
        };
      };
    };
  };

  config.cluster.certificates.provider = lib.mkDefault "acme";
}
