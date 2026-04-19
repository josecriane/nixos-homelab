{
  description = "NixOS Homelab - Declarative K3s homelab on NixOS";

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
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-k8s,
      ...
    }:
    let
      # config.nix and secrets/ are gitignored, so we read them from
      # the real filesystem using PWD (requires --impure)
      projectDir = builtins.getEnv "PWD";
      impureMsg = "Gitignored files not accessible; build with --impure (update.sh does this automatically)";
      configPath = if projectDir != "" then "${projectDir}/config.nix" else throw impureMsg;
      # builtins.path copies files to the nix store so they're available
      # on the server after deployment (filter excludes private keys)
      secretsPath =
        if projectDir != "" then
          builtins.path {
            path = "${projectDir}/secrets";
            name = "homelab-secrets";
            filter = path: type: type == "regular";
          }
        else
          throw impureMsg;

      rawConfig = import configPath;

      # Project the homelab config onto the multi-node schema that nixos-k8s
      # modules (k3s, metallb, traefik, cert-manager, ...) expect. Defaults
      # are conservative: k3s+flannel, ACME certs, CIDRs mirror nixos-k8s.
      serverConfig = rawConfig // {
        kubernetes = {
          engine = "k3s";
          cni = "flannel";
          podCidr = "10.42.0.0/16";
          serviceCidr = "10.43.0.0/16";
        }
        // (rawConfig.kubernetes or { });

        certificates = {
          provider = "acme";
        }
        // (rawConfig.certificates or { });
      };

      bootstrapName = builtins.head (
        builtins.attrNames (nixpkgs.lib.filterAttrs (_: n: n.bootstrap or false) serverConfig.nodes)
      );

      # Delegate cluster build to nixos-k8s. Upstream loads its own
      # modules/{core,services,kubernetes}; homelab adds its layer via extraModules.
      clusterConfigs = nixos-k8s.lib.mkCluster {
        clusterConfig = serverConfig;
        hostsPath = "${self}/hosts";
        inherit secretsPath;
        extraSpecialArgs = { inherit nixos-k8s; };
        extraModules = [
          ./modules/core
          ./modules/services
          ./modules/kubernetes
        ];
      };
    in
    {
      nixosConfigurations = clusterConfigs // {
        # Backwards-compat alias: `nixos-rebuild --flake .#homelab` still works
        homelab = clusterConfigs.${bootstrapName};
      };

      formatter = nixos-k8s.formatter;

      devShells = nixos-k8s.devShells;
    };
}
