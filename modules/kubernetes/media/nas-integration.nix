{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "nas";
  markerFile = "/var/lib/nas-integration-setup-done";

  # Detect old single-NAS config vs new multi-NAS config
  rawNasConfig = serverConfig.nas or { };

  # Check if it's old format (has 'ip' directly) or new format (attribute set of NAS)
  isOldFormat = rawNasConfig ? ip;

  # Normalize to new format
  nasConfig =
    if isOldFormat then
      # Convert old format to new format with migration warning
      {
        nas1 = rawNasConfig // {
          hostname = "nas"; # Backward compatible hostname
          description = "Primary NAS";
        };
      }
    else
      # Already new format, use as-is
      rawNasConfig;

  # Filter only enabled NAS
  enabledNAS = lib.filterAttrs (name: cfg: cfg.enabled or false) nasConfig;

  # Check if any NAS is enabled
  anyNasEnabled = (builtins.length (builtins.attrNames enabledNAS)) > 0;

  # Generate Endpoints + Service for a NAS service
  generateNASService = nasName: nasCfg: serviceName: servicePort: ''
        echo "Creating Endpoints and Service for ${nasName}-${serviceName}..."
        cat <<EOF | $KUBECTL apply -f -
    ---
    apiVersion: v1
    kind: Endpoints
    metadata:
      name: ${nasName}-${serviceName}
      namespace: ${ns}
    subsets:
      - addresses:
          - ip: ${nasCfg.ip}
        ports:
          - port: ${toString servicePort}
            name: http
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: ${nasName}-${serviceName}
      namespace: ${ns}
    spec:
      ports:
        - port: ${toString servicePort}
          targetPort: ${toString servicePort}
          name: http
    EOF
  '';

  # Generate all resources for a single NAS
  generateNASResources = nasName: nasCfg: ''
    echo "=========================================="
    echo "Configuring ${nasName}: ${nasCfg.description or nasName}"
    echo "IP: ${nasCfg.ip}"
    echo "=========================================="

    # Cockpit
    ${generateNASService nasName nasCfg "cockpit" (nasCfg.cockpitPort or 9090)}

    # FileBrowser
    ${generateNASService nasName nasCfg "filebrowser" (nasCfg.fileBrowserPort or 8080)}

    # IngressRoutes
    echo "Creating IngressRoutes for ${nasName}..."

    # Cockpit IngressRoute
    create_ingress_route "${nasName}-cockpit" "${ns}" "$(hostname ${nasCfg.hostname or nasName})" "${nasName}-cockpit" "${
      toString (nasCfg.cockpitPort or 9090)
    }" "authentik-forward-auth:traefik-system"

    # FileBrowser IngressRoute
    create_ingress_route "${nasName}-filebrowser" "${ns}" "$(hostname files${
      lib.removePrefix "nas" (nasCfg.hostname or nasName)
    })" "${nasName}-filebrowser" "${
      toString (nasCfg.fileBrowserPort or 8080)
    }" "authentik-forward-auth:traefik-system"
  '';

  # Generate all NAS configurations
  allNASResources = lib.concatStringsSep "\n\n" (lib.mapAttrsToList generateNASResources enabledNAS);

  # Build summary for success message
  successUrls = lib.flatten (
    lib.mapAttrsToList (nasName: nasCfg: [
      {
        name = "${nasName} Cockpit";
        url = "https://${k8s.hostname (nasCfg.hostname or nasName)}";
      }
      {
        name = "${nasName} Files";
        url = "https://${k8s.hostname "files${lib.removePrefix "nas" (nasCfg.hostname or nasName)}"}";
      }
    ]) enabledNAS
  );

  successNotes = [
    "NAS services exposed through Traefik"
    "Protected with Authentik ForwardAuth"
    "NAS configured: ${toString (builtins.length (builtins.attrNames enabledNAS))}"
  ]
  ++ (lib.mapAttrsToList (
    nasName: nasCfg: "  - ${nasName}: ${nasCfg.ip} (${nasCfg.description or nasName})"
  ) enabledNAS)
  ++ [
    "Applications must be configured in Authentik"
  ];
in
lib.mkIf anyNasEnabled {
  # Show migration warning if old format is detected
  warnings = lib.optional isOldFormat ''
    WARNING: Old NAS configuration format detected in config.nix
    The single 'nas' configuration has been automatically migrated to 'nas.nas1'
    Please update your config.nix to use the new multi-NAS format:

    nas = {
      nas1 = {
        enabled = true;
        ip = "192.168.1.100";
        hostname = "nas1";
        cockpitPort = 9090;
        fileBrowserPort = 8080;
        description = "Primary NAS";
      };
    };
  '';
  systemd.services.nas-integration-setup = {
    description = "Setup NAS integration with Traefik and Authentik";
    # After media
    after = [
      "k3s-media.target"
      "authentik-sso-setup.service"
    ];
    requires = [ "k3s-media.target" ];
    wants = [ "authentik-sso-setup.service" ];
    wantedBy = [ "k3s-extras.target" ];
    before = [ "k3s-extras.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nas-integration-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "NAS Integration"

        wait_for_k3s
        wait_for_traefik
        wait_for_certificate

        # Setup namespace
        setup_namespace "${ns}"

        # ============================================
        # MULTI-NAS CONFIGURATION
        # ============================================

        ${allNASResources}

        echo ""
        echo "========================================="
        echo "NAS Integration installed successfully"
        echo ""
        echo "URLs:"
        ${lib.concatMapStringsSep "\n" (u: ''echo "  ${u.name}: ${u.url}"'') successUrls}
        echo ""
        ${lib.concatMapStringsSep "\n" (n: ''echo "${n}"'') successNotes}
        echo "========================================="
        echo ""

        create_marker "${markerFile}"
      '';
    };
  };
}
