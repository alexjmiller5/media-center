{
  description = "Media Center signed macOS application";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/2bd3427b41d10b8318383195efe502ed1baca6cd";

  outputs = { nixpkgs, ... }:
    let
      darwinSystems = [ "aarch64-darwin" "x86_64-darwin" ];
      forSystems = f: nixpkgs.lib.genAttrs darwinSystems (system: f nixpkgs.legacyPackages.${system});
      homeModule = import ./nix/home-manager.nix;
    in {
      packages = forSystems (pkgs:
        let package = pkgs.callPackage ./nix/package.nix {}; in {
          default = package;
          media-center = package;
        });
      darwinModules.default = import ./nix/darwin.nix;
      darwinModules.media-center = import ./nix/darwin.nix;
      homeModules.default = homeModule;
      homeModules.media-center = homeModule;
      checks = forSystems (pkgs: import ./nix/checks.nix {
        inherit pkgs homeModule;
        package = pkgs.callPackage ./nix/package.nix {};
      });
    };
}
