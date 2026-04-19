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
      url = "path:/home/sito/dev/devops/nixos-k8s";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
      inputs.agenix.follows = "agenix";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      agenix,
      nixos-k8s,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

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

      mkHost =
        hostName:
        let
          rawConfig = import configPath;

          # Adapter: the single-host homelab config is projected onto the
          # multi-node schema that nixos-k8s modules (k3s, metallb, traefik,
          # cert-manager, ...) expect in specialArgs. Existing homelab
          # modules ignore the new fields since they read from serverConfig
          # under their legacy names. Defaults are conservative: one bootstrap
          # server with k3s+flannel, manual certs, CIDRs mirror nixos-k8s.
          nodeName = rawConfig.serverName;

          syntheticNode = {
            ip = rawConfig.serverIP;
            role = "server";
            bootstrap = true;
          };

          serverConfig = rawConfig // {
            nodes = rawConfig.nodes or { ${nodeName} = syntheticNode; };

            kubernetes = {
              engine = "k3s";
              cni = "flannel";
              podCidr = "10.42.0.0/16";
              serviceCidr = "10.43.0.0/16";
            } // (rawConfig.kubernetes or { });

            certificates = {
              provider = "acme";
            } // (rawConfig.certificates or { });
          };

          bootstrapEntry = nixpkgs.lib.findFirst (n: n.bootstrap or false) syntheticNode (
            nixpkgs.lib.attrValues serverConfig.nodes
          );

          nodeConfig = serverConfig.nodes.${nodeName} // {
            name = nodeName;
            bootstrapIP = bootstrapEntry.ip;
          };

          clusterNodes = nixpkgs.lib.mapAttrsToList (name: cfg: cfg // { inherit name; }) serverConfig.nodes;
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit
              inputs
              serverConfig
              secretsPath
              nixos-k8s
              nodeConfig
              clusterNodes
              ;
          };
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.default
            ./hosts/${hostName}
            ./modules/core
            ./modules/services
            ./modules/kubernetes
          ];
        };
    in
    {
      nixosConfigurations.homelab = mkHost "default";

      formatter.${system} = pkgs.nixfmt-rfc-style;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nixos-anywhere
          kubectl
          kubernetes-helm
          k9s
          age
          jq
          yq-go
        ];
        shellHook = ''
          echo "NixOS Homelab - Dev Shell"
          echo "Commands:"
          echo "  ./scripts/setup.sh   - Initial configuration"
          echo "  ./scripts/install.sh - Install on server (FORMATS DISK)"
          echo "  ./scripts/update.sh  - Update configuration"
        '';
      };
    };
}
