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
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      agenix,
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
          serverConfig = import configPath;
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs serverConfig secretsPath; };
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
