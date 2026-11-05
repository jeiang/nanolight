self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.nanolight;
  configFile = "/etc/nanolight/config.toml";
in {
  imports = [(import ./client-options.nix self)];

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cfg.package];
    environment.etc."nanolight/config.toml".source = (pkgs.formats.toml {}).generate "nanolight-config.toml" cfg.settings;

    systemd.user.services.nanolight = {
      description = "Nanolight launcher";
      wantedBy = ["graphical-session.target"];
      partOf = ["graphical-session.target"];
      after = ["graphical-session.target"];
      # The default path would pin PATH to coreutils and friends; the unit must see the session PATH.
      path = lib.mkForce [];
      environment.NANOLIGHT_CONFIG = configFile;
      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
      };
    };
  };
}
