{
  lib,
  serverConfig,
  nodeConfig,
  ...
}:

let
  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;
  isBootstrap = nodeConfig.bootstrap or false;
  onBootstrap = name: isBootstrap && (enabled name);

  needsAuthentik = lib.filter enabled [
    "paperless"
    "stirling-pdf"
  ];
in
{
  imports =
    lib.optionals (onBootstrap "paperless") [
      ./paperless
    ]
    ++ lib.optionals (onBootstrap "stirling-pdf") [
      ./stirling-pdf
    ];

  assertions = [
    {
      assertion = needsAuthentik == [ ] || (enabled "authentik");
      message =
        "services.authentik must be true when ${lib.concatStringsSep ", " needsAuthentik} is enabled: "
        + "these apps authenticate through its OIDC provider.";
    }
  ];
}
