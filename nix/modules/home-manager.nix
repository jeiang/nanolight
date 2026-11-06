self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.nanolight;
  configPath = "${config.xdg.configHome}/nanolight/config.toml";
  exe = lib.getExe cfg.package;
in {
  imports = [(import ./client-options.nix self)];

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      home.packages = [cfg.package];
      xdg.configFile."nanolight/config.toml".source = cfg.configFile;
    }
    (lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
      systemd.user.services.nanolight = {
        Unit = {
          Description = "Nanolight launcher";
          After = ["graphical-session.target"];
          PartOf = ["graphical-session.target"];
        };
        Service = {
          ExecStart = exe;
          Environment = ["NANOLIGHT_CONFIG=${configPath}"];
          Restart = "on-failure";
        };
        Install.WantedBy = ["graphical-session.target"];
      };
    })
    (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      launchd.agents.nanolight = {
        enable = true;
        config = import ./launch-agent.nix {inherit exe configPath;};
      };
    })
  ]);
}
