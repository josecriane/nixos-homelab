{ lib, ... }:

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

  imports = [
    ./blueprint.nix
    ./authentik.nix
    ./sso.nix
    ./ldap.nix
    ./google-source.nix
    ./authentik-users.nix
  ];
}
