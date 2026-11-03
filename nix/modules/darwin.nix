self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.nanolight;
  user = config.system.primaryUser;
  configFile = "/etc/nanolight/config.toml";
  storeApp = "${cfg.package}/Applications/Nanolight.app";
  installedApp = "/Applications/Nanolight.app";
  stamp = "/var/db/nanolight/app-source";
  signed = cfg.codesignIdentity != null;
  exe =
    if signed
    then "${installedApp}/Contents/MacOS/nanolight"
    else lib.getExe cfg.package;
in {
  imports = [(import ./client-options.nix self)];

  options.programs.nanolight = {
    codesignIdentity = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Apple Development: Jane Doe (ABCDE12345)";
      description = ''
        A signing identity in the primary user's login keychain. When set, the app is
        copied to /Applications/Nanolight.app and signed there with it, and the launch
        agent runs that copy. The Accessibility grant then survives rebuilds, because
        macOS ties it to the signature. When null, the app from the Nix store runs with
        its ad-hoc signature, and the grant is lost on each rebuild.
      '';
    };
    disableSpotlightShortcut = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Turn off Spotlight's Command-Space shortcut (symbolic hotkey 64), which Nanolight's default hotkey uses.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(signed || cfg.disableSpotlightShortcut) || user != null;
        message = "programs.nanolight needs system.primaryUser to sign the app or to change Spotlight's shortcut.";
      }
    ];

    environment.systemPackages = [cfg.package];
    environment.etc."nanolight/config.toml".source = (pkgs.formats.toml {}).generate "nanolight-config.toml" cfg.settings;

    launchd.user.agents.nanolight.serviceConfig = {
      ProgramArguments = [exe];
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      EnvironmentVariables.NANOLIGHT_CONFIG = configFile;
      ProcessType = "Interactive";
    };

    system.activationScripts.postActivation.text = lib.concatStrings [
      (lib.optionalString signed ''
        if [ "$(cat ${stamp} 2>/dev/null)" != "${storeApp}" ] || ! sudo -u ${user} codesign --verify ${installedApp} 2>/dev/null; then
          echo "signing ${installedApp} with ${cfg.codesignIdentity}..." >&2
          rm -rf ${installedApp}
          cp -R ${storeApp} ${installedApp}
          chown -R ${user} ${installedApp}
          chmod -R u+w ${installedApp}
          if sudo -u ${user} codesign --force --deep --sign ${lib.escapeShellArg cfg.codesignIdentity} ${installedApp}; then
            mkdir -p "$(dirname ${stamp})"
            echo "${storeApp}" > ${stamp}
            uid=$(id -u ${user})
            launchctl kickstart -k "gui/$uid/org.nixos.nanolight" 2>/dev/null || true
          else
            echo "warning: codesign failed; is the identity in ${user}'s login keychain?" >&2
          fi
        fi
      '')
      (lib.optionalString cfg.disableSpotlightShortcut ''
        sudo -u ${user} defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 64 \
          '{ enabled = 0; value = { parameters = (32, 49, 1048576); type = standard; }; }'
        sudo -u ${user} /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u || true
      '')
    ];
  };
}
