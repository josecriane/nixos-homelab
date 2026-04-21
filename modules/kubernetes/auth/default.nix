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
