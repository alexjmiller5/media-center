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
  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = pkgs.stdenv.hostPlatform.isDarwin;
      message = "programs.media-center installs the macOS app and requires macOS.";
    }];
    home.packages = [ cfg.package ];
  };
}
