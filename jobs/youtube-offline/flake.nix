{
  description = "Media Center YouTube offline job: keeps requested videos as offline copies in a Soma hub (mac mini, outbound long poll)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, uv2nix, pyproject-nix, pyproject-build-systems }:
    let
      inherit (nixpkgs) lib;
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
      overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
      mkPythonSet = pkgs:
        (pkgs.callPackage pyproject-nix.build.packages { python = pkgs.python313; }).overrideScope (
          lib.composeManyExtensions [ pyproject-build-systems.overlays.default overlay ]
        );

      # The locked venv, with yt-dlp and ffmpeg from nixpkgs on its PATH.
      package = pkgs:
        let venv = (mkPythonSet pkgs).mkVirtualEnv "media-center-youtube-offline-env" workspace.deps.default;
        in pkgs.runCommand "youtube-offline"
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
            meta.mainProgram = "youtube-offline";
          } ''
          makeWrapper ${venv}/bin/youtube-offline $out/bin/youtube-offline \
            --prefix PATH : ${lib.makeBinPath [ pkgs.yt-dlp pkgs.ffmpeg ]}
        '';
    in
    {
      packages = forAllSystems (pkgs: rec {
        youtube-offline = package pkgs;
        default = youtube-offline;
      });

      darwinModules.default = import ./nix/darwin.nix self;

      checks = forAllSystems (pkgs: {
        cli = pkgs.runCommand "youtube-offline-cli" { } ''
          ${lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.default} --help
          ${lib.getExe pkgs.yt-dlp} --version
          touch $out
        '';
      });
    };
}
