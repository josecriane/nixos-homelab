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
    }@inputs:
    let
      withHomelabDefaults = cfg: nixpkgs.lib.recursiveUpdate (import ./modules/homelab-defaults.nix) cfg;

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
            "${self}/modules/options.nix"
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
        else
          { };
    in
    {
      lib = {
        inherit mkHomelab;
      };

      nixosConfigurations = standaloneConfigs;

      checks.x86_64-linux =
        let
          base = import "${self}/config.example.nix";
          mkVariant =
            suffix: overrides:
            nixpkgs.lib.mapAttrs'
              (name: node: nixpkgs.lib.nameValuePair "${name}${suffix}" node.config.system.build.toplevel)
              (mkHomelab {
                clusterConfig = base // overrides;
                hostsPath = "${self}/hosts";
                secretsPath = "${self}/secrets";
              });
        in
        mkVariant "" { }
        // mkVariant "-all-services" {
          services = nixpkgs.lib.mapAttrs (_: _: true) base.services;
        };

      apps = nixos-k8s.apps;

      formatter = nixos-k8s.formatter;

      devShells = nixos-k8s.devShells;
    };
}
