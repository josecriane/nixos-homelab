{ config, lib, ... }:

let
  svc = config.cluster.services;

  needsAuthentik = lib.filter (name: svc.${name}) [
    "paperless"
    "stirling-pdf"
  ];
in
{
  imports = [
    ./paperless
    ./paperless/backup.nix
    ./stirling-pdf
  ];

  assertions = [
    {
      assertion = needsAuthentik == [ ] || svc.authentik;
      message =
        "services.authentik must be true when ${lib.concatStringsSep ", " needsAuthentik} is enabled: "
        + "these apps authenticate through its OIDC provider.";
    }
  ];
}
