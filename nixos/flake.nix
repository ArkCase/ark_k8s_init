{
  description = "ArkCase single-node Kubernetes host layer for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Add to your configuration with:
      #   imports = [ inputs.ark-k8s-init.nixosModules.default ];
      #   services.arkcase-k8s.enable = true;
      nixosModules.default = import ./module.nix;
      nixosModules.arkcase-k8s = import ./module.nix;

      # `nix develop` gives you the client-side tooling without enabling the host
      # layer -- useful for driving a cluster that lives somewhere else.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            kubernetes
            kubernetes-helm
            kubectl-view-secret
            cri-tools
            nssTools
            gh
            act
            jq
            yq-go
            moreutils
            gettext
            openssl
          ];
        };
      });
    };
}
