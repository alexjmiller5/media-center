{ pkgs, package, homeModule }:
let
  inherit (pkgs) lib;
  sample = pkgs.runCommand "media-center-package-fixture" { nativeBuildInputs = [ pkgs.zip ]; } ''
    mkdir -p MediaCenter.app/Contents/{MacOS,Resources,_CodeSignature}
    printf '#!/bin/sh\nprintf signed-payload' > MediaCenter.app/Contents/MacOS/MediaCenter
    chmod +x MediaCenter.app/Contents/MacOS/MediaCenter
    printf profile > MediaCenter.app/Contents/embedded.provisionprofile
    printf ticket > MediaCenter.app/Contents/CodeResources
    printf signature > MediaCenter.app/Contents/_CodeSignature/CodeResources
    ln -s ../MacOS/MediaCenter MediaCenter.app/Contents/Resources/executable
    zip -qry fixture.zip MediaCenter.app
    mv fixture.zip "$out"
  '';
  fixturePackage = package.overrideAttrs { src = sample; };
  stub = {
    options = {
      environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; };
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
      homebrew.casks = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
    };
  };
  evaluate = module: settings: (lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [ module stub settings ];
  }).config;
  passes = config: lib.all (entry: entry.assertion) config.assertions;
  darwin = evaluate ./darwin.nix;
  home = evaluate homeModule;
  fixture = { programs.media-center = { enable = true; package = fixturePackage; }; };
  customRelease = package.override {
    version = "1.2.3";
    url = "https://example.invalid/releases/app.zip";
    hash = lib.fakeHash;
  };
in {
  darwin-module = assert (darwin {}).environment.systemPackages == [];
    assert (darwin fixture).environment.systemPackages == [ fixturePackage ];
    assert passes (darwin fixture);
    assert ((darwin { programs.media-center.enable = true; }).environment.systemPackages == [ package ]);
    assert !passes (darwin (fixture // { homebrew.casks = [{ name = "alexjmiller5/tap/media-center"; }]; }));
    pkgs.runCommand "media-center-darwin-module-check" {} "touch $out";
  home-module = assert (home {}).home.packages == [];
    assert (home fixture).home.packages == [ fixturePackage ];
    assert passes (home fixture);
    assert customRelease.version == "1.2.3";
    assert customRelease.src.url == "https://example.invalid/releases/app.zip";
    pkgs.runCommand "media-center-home-module-check" {} "touch $out";
  bundle-preservation = pkgs.runCommand "media-center-bundle-preservation-check" {
    nativeBuildInputs = [ pkgs.unzip pkgs.diffutils ];
  } ''
    unzip -q ${sample}
    diff -r --no-dereference MediaCenter.app ${fixturePackage}/Applications/MediaCenter.app
    test -x ${fixturePackage}/Applications/MediaCenter.app/Contents/MacOS/MediaCenter
    test "$(readlink ${fixturePackage}/Applications/MediaCenter.app/Contents/Resources/executable)" = ../MacOS/MediaCenter
    touch "$out"
  '';
}
