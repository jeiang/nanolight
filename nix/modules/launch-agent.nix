# The launch agent both macOS modules (nix-darwin, home-manager) run: started
# at login, restarted when it crashes but not after Quit.
{
  exe,
  configPath,
}: {
  ProgramArguments = [exe];
  RunAtLoad = true;
  KeepAlive.SuccessfulExit = false;
  EnvironmentVariables.NANOLIGHT_CONFIG = configPath;
  ProcessType = "Interactive";
}
