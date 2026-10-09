# nix-darwin module: the YouTube offline job as a kept-alive launchd user agent
# (`youtube-offline watch`) that long-polls a Soma hub subscription on
# youtube_videos.offline_requested. The hub never reaches into this machine.
#
# Runs in the login session (gui/<uid>) so credentialCommand can read the
# login Keychain, which ssh-descended shells cannot.
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.media-center.youtube-offline;
  environment = {
    HOME = "/Users/${cfg.user}";
    YOUTUBE_OFFLINE_HUB_URL = cfg.hubUrl;
    YOUTUBE_OFFLINE_SUBSCRIPTION_ID = cfg.subscriptionId;
    YOUTUBE_OFFLINE_STATE_DIR = cfg.stateDir;
    YOUTUBE_OFFLINE_STORAGE_CAP_BYTES = toString cfg.storageCapBytes;
  } // lib.optionalAttrs (cfg.credentialCommand != [ ]) {
    YOUTUBE_OFFLINE_TOKEN_COMMAND = builtins.toJSON cfg.credentialCommand;
  } // lib.optionalAttrs (cfg.format != null) {
    YOUTUBE_OFFLINE_FORMAT = cfg.format;
  };
in
{
  options.services.media-center.youtube-offline = {
    enable = lib.mkEnableOption "keeping requested YouTube videos as offline copies in a Soma hub";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      description = "The installed job package (yt-dlp and ffmpeg included).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "Login user whose session runs the agent and owns its state.";
      example = "local-user";
    };

    hubUrl = lib.mkOption {
      type = lib.types.str;
      description = "HTTPS origin of the Soma hub.";
      example = "https://soma.example.workers.dev";
    };

    subscriptionId = lib.mkOption {
      type = lib.types.str;
      description = "Hub subscription on youtube_videos.offline_requested that this job consumes.";
    };

    credentialCommand = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        argv printing this job's own hub token, run in the agent's login session
        (e.g. a login-Keychain lookup). Never put the token itself in Nix.
      '';
      example = [ "/usr/bin/security" "find-generic-password" "-s" "media-center.youtube-offline" "-a" "hub" "-w" ];
    };

    storageCapBytes = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 5000000000;
      description = "Total bytes of retained videos; new downloads are refused (visibly, on the row) at the cap.";
    };

    format = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "yt-dlp format selector (default: best mp4 at <= 720p).";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/Users/${cfg.user}/.local/state/media-center/youtube-offline";
      defaultText = lib.literalExpression ''"/Users/''${user}/.local/state/media-center/youtube-offline"'';
      description = "Retry state, download spool and log (XDG state dir).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    system.activationScripts.postActivation.text = lib.mkAfter ''
      # launchd opens StandardOutPath before the job runs.
      /usr/bin/sudo -u ${lib.escapeShellArg cfg.user} /bin/mkdir -p ${lib.escapeShellArg cfg.stateDir}
    '';

    launchd.user.agents.media-center-youtube-offline.serviceConfig = {
      Label = "com.alexmiller.media-center.youtube-offline";
      ProgramArguments = [ (lib.getExe cfg.package) "watch" ];
      EnvironmentVariables = environment;
      RunAtLoad = true;
      KeepAlive = true;
      # A crashing job restarts at most every 30 s; the job itself never spins.
      ThrottleInterval = 30;
      ProcessType = "Background";
      WorkingDirectory = cfg.stateDir;
      StandardOutPath = "${cfg.stateDir}/youtube-offline.log";
      StandardErrorPath = "${cfg.stateDir}/youtube-offline.log";
    };
  };
}
