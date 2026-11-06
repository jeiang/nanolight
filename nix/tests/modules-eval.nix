# Checks what the client and server modules set (evals.nix evaluates them).
{
  self,
  nixpkgs,
  pkgs,
}: let
  lib = nixpkgs.lib;
  inherit (import ./evals.nix {inherit self nixpkgs pkgs;}) nixos darwin home homeDarwin;

  agent = darwin.config.launchd.user.agents.nanolight.serviceConfig;
  homeAgent = homeDarwin.config.launchd.agents.nanolight.config;
  facts = {
    nixosUnitKeepsSessionPath = !(nixos.config.systemd.user.services.nanolight.environment ? PATH);
    serverRetriesPastStartLimit = nixos.config.systemd.services.nanolight-server.startLimitIntervalSec == 0;
    nixosUnit = nixos.config.systemd.user.services.nanolight.environment.NANOLIGHT_CONFIG == "/etc/nanolight/config.toml";
    serverUnit = nixos.config.systemd.services.nanolight-server.serviceConfig.DynamicUser;
    firewall = lib.elem 8890 nixos.config.networking.firewall.allowedTCPPorts;
    darwinKeepAlive = agent.KeepAlive == {SuccessfulExit = false;};
    darwinRunsSignedCopy = lib.hasPrefix "/Applications/Nanolight.app/" (lib.head agent.ProgramArguments);
    darwinSpotlight = lib.hasInfix "AppleSymbolicHotKeys -dict-add 64" darwin.config.system.activationScripts.postActivation.text;
    darwinKickstartsConfiguredLabel = lib.hasInfix "kickstart -k \"gui/$uid/\"'dev.example.nano light'" darwin.config.system.activationScripts.postActivation.text;
    homeUnit = home.config.systemd.user.services.nanolight.Service.Restart == "on-failure";
    homeLinuxHasNoAgent = !(home.config.launchd.agents ? nanolight);
    homeDarwinAgent = homeDarwin.config.launchd.agents.nanolight.enable;
    homeDarwinKeepAlive = homeAgent.KeepAlive == {SuccessfulExit = false;};
    homeDarwinConfigPath = homeAgent.EnvironmentVariables.NANOLIGHT_CONFIG == "/Users/jane/.config/nanolight/config.toml";
    homeDarwinRunsStoreApp = lib.hasSuffix "/bin/nanolight" (lib.head homeAgent.ProgramArguments);
    homeDarwinHasNoUnit = !(homeDarwin.config.systemd.user.services ? nanolight);
  };
in
  assert lib.assertMsg (lib.all lib.id (lib.attrValues facts)) "module eval: ${builtins.toJSON facts}";
    pkgs.runCommand "modules-eval" {} ''
      echo ${builtins.unsafeDiscardStringContext nixos.config.system.build.toplevel.drvPath} > $out
    ''
