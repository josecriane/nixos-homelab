{
  description = "NixOS Homelab - Declarative K3s homelab on NixOS (library flake)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-k8s = {
      url = "github:josecriane/nixos-k8s";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
      inputs.agenix.follows = "agenix";
    };
    switchboard = {
      url = "github:josecriane/switchboard";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-k8s,
      switchboard,
      ...
    }:
    let
      # Homelab defaults layered onto raw clusterConfig. Upstream modules
      # are inconsistent about default cert provider (tls-secret.nix defaults
      # to "manual" while traefik.nix defaults to "acme"), so pin "acme" here.
      withHomelabDefaults =
        cfg:
        cfg
        // {
          kubernetes = {
            engine = "k3s";
            cni = "flannel";
            podCidr = "10.42.0.0/16";
            serviceCidr = "10.43.0.0/16";
          }
          // (cfg.kubernetes or { });
          certificates = {
            provider = "acme";
          }
          // (cfg.certificates or { });
        };

      mkHomelab =
        {
          clusterConfig,
          hostsPath,
          secretsPath,
          extraModules ? [ ],
          extraSpecialArgs ? { },
        }:
        nixos-k8s.lib.mkCluster {
          clusterConfig = withHomelabDefaults clusterConfig;
          inherit hostsPath secretsPath;
          extraSpecialArgs = {
            inherit nixos-k8s switchboard;
            nixos-homelab = self;
          }
          // extraSpecialArgs;
          extraModules = [
            "${self}/modules/core"
            "${self}/modules/services"
            "${self}/modules/kubernetes"
          ]
          ++ extraModules;
        };

      bootstrapOf =
        cfg:
        builtins.head (builtins.attrNames (nixpkgs.lib.filterAttrs (_: n: n.bootstrap or false) cfg.nodes));

      hasLocalConfig = builtins.pathExists "${self}/config.nix";
      projectDir = builtins.getEnv "PWD";
      impureSecrets = builtins.path {
        path = "${projectDir}/secrets";
        name = "homelab-secrets";
        filter = _: type: type == "regular";
      };

      standaloneConfigs =
        if hasLocalConfig then
          let
            cfg = import "${self}/config.nix";
            c = mkHomelab {
              clusterConfig = cfg;
              hostsPath = "${self}/hosts";
              secretsPath = "${self}/secrets";
            };
          in
          c // { homelab = c.${bootstrapOf cfg}; }
        else if projectDir != "" && builtins.pathExists "${projectDir}/config.nix" then
          let
            cfg = import "${projectDir}/config.nix";
            c = mkHomelab {
              clusterConfig = cfg;
              hostsPath = "${self}/hosts";
              secretsPath = impureSecrets;
            };
          in
          c // { homelab = c.${bootstrapOf cfg}; }
        else
          { };
    in
    {
      lib.mkHomelab = mkHomelab;

      nixosConfigurations = standaloneConfigs;

      apps = nixos-k8s.apps;

      formatter = nixos-k8s.formatter;

      devShells = nixos-k8s.devShells;
    };
}
