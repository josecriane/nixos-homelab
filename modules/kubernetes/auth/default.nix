{
  lib,
  serverConfig,
  nodeConfig,
  ...
}:

let
  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;
  nas = serverConfig.nas or { };
  anyNas =
    (builtins.length (builtins.attrNames (lib.filterAttrs (_: c: c.enabled or false) nas))) > 0;
  isBootstrap = nodeConfig.bootstrap or false;
  authentikOn = isBootstrap && (enabled "authentik");
in
{
  options.sso.oidcApps = lib.mkOption {
    description = ''
      OIDC applications an app module wants Authentik to provide. sso.nix creates
      a provider plus application for each one, generates and reuses its client
      secret, and adds CLIENT_ID/CLIENT_SECRET to the authentik-sso-credentials
      secret, copied into `namespace`. `redirectPaths` are appended to the app's
      own https://<host>.<domain> URL, so they must match what the app expects.
    '';
    default = [ ];
    type = lib.types.listOf (
      lib.types.submodule {
        freeformType = lib.types.attrs;
        options = {
          name = lib.mkOption { type = lib.types.str; };
          slug = lib.mkOption { type = lib.types.str; };
          host = lib.mkOption { type = lib.types.str; };
          namespace = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          redirectPaths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
        };
      }
    );
  };

  imports =
    lib.optionals authentikOn [
      ./authentik.nix
      ./sso.nix
    ]
    ++ lib.optionals (authentikOn && (serverConfig.authentik.ldap.enable or false)) [
      ./ldap.nix
    ]
    ++ lib.optionals (authentikOn && (serverConfig.authentik.bootstrapUsers or { }) != { }) [
      ./authentik-users.nix
    ]
    ++ lib.optionals (authentikOn && anyNas) [
      ./nas-apps.nix
    ];
}
