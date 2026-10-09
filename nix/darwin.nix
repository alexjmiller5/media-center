{ config, lib, pkgs, ... }:
let cfg = config.programs.media-center;
in {
  options.programs.media-center = {
    enable = lib.mkEnableOption "the Media Center macOS app";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {};
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix {}";
      description = "The signed Media Center release to install, unmodified.";
    };
  };
  # nix-darwin links system packages' apps into /Applications/Nix Apps.
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    assertions = [{
      assertion = !(lib.any (cask: lib.last (lib.splitString "/" cask.name) == "media-center") config.homebrew.casks);
      message = "Remove the media-center cask declaration when enabling its Nix module.";
    }];
  };
}
