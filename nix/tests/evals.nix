# The module evaluations the checks share (modules-eval.nix, config-parse.nix).
# The NixOS modules run in a real system; nix-darwin and home-manager are not
# inputs, so their modules run against stand-ins for the few options they set
# (this checks the module logic, not that those options exist upstream).
{
  self,
  nixpkgs,
  pkgs,
}: let
  lib = nixpkgs.lib;

  # Every key the README's Configuration section documents, so that
  # config-parse reads each one as the modules write it.
  settings = {
    hotkey = "opt_space";
    suggestions = true;
    open_searches_in_browser = false;
    show_in_menu_bar = true;
    pop_to_root_seconds = 90;
    apps.extra_dirs = ["/opt/apps"];
    script_commands.dirs = ["scripts" "/srv/nanolight scripts"];
    quicklinks = [
      {
        name = "DuckDuckGo";
        url = "https://duckduckgo.com/?q={argument}";
        keyword = "ddg";
      }
      {
        name = "Kagi";
        url = "https://kagi.com/search?q={argument}";
      }
    ];
    clipboard = {
      enabled = true;
      retention_days = 7;
      max_entries = 1000;
      paste_plain_text = true;
      exclude_apps = ["com.bitwarden.desktop" "com.yubico.yubioath"];
    };
    sync = {
      url = "http://127.0.0.1:8890";
      token_file = "/run/secrets/nanolight-token";
    };
  };

  stubs = {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.raw;
        default = [];
      };
      environment.systemPackages = lib.mkOption {type = lib.types.listOf lib.types.package;};
      environment.etc = lib.mkOption {type = lib.types.attrsOf lib.types.raw;};
      launchd.user.agents = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options.serviceConfig = lib.mkOption {type = lib.types.attrsOf lib.types.raw;};
        });
      };
      system.activationScripts.postActivation.text = lib.mkOption {type = lib.types.lines;};
      system.primaryUser = lib.mkOption {type = lib.types.nullOr lib.types.str;};
      home.packages = lib.mkOption {type = lib.types.listOf lib.types.package;};
      xdg.configHome = lib.mkOption {type = lib.types.str;};
      xdg.configFile = lib.mkOption {type = lib.types.attrsOf lib.types.raw;};
      systemd.user.services = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        default = {};
      };
      launchd.agents = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        default = {};
      };
    };
  };

  evalStub = modulePkgs: module: modules:
    lib.evalModules {
      specialArgs.pkgs = modulePkgs;
      modules = [stubs module] ++ modules;
    };

  homeWith = modulePkgs: configHome: settings:
    evalStub modulePkgs self.homeManagerModules.default [
      {
        xdg.configHome = configHome;
        programs.nanolight = {
          enable = true;
          inherit settings;
        };
      }
    ];

  # A file the app would not take all of, as home-manager writes it.
  refused = settings: (homeWith pkgs "/home/jane/.config" settings).config.programs.nanolight.configFile;
in {
  nixos = nixpkgs.lib.nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      self.nixosModules.default
      self.nixosModules.server
      {
        programs.nanolight = {
          enable = true;
          inherit settings;
        };
        services.nanolight-server = {
          enable = true;
          tokensFile = "/run/secrets/nanolight-tokens";
          openFirewall = true;
        };
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        system.stateVersion = "25.11";
      }
    ];
  };

  darwin = evalStub pkgs self.darwinModules.default [
    {
      system.primaryUser = "jane";
      launchd.user.agents.nanolight.serviceConfig.Label = "dev.example.nano light";
      programs.nanolight = {
        enable = true;
        inherit settings;
        codesignIdentity = "Apple Development: Jane Doe";
      };
    }
  ];

  home = homeWith pkgs "/home/jane/.config" settings;
  # Evaluated with macOS packages, for the module's launchd branch (never built).
  homeDarwin = homeWith nixpkgs.legacyPackages.aarch64-darwin "/Users/jane/.config" settings;

  misspelledKey = refused {sugestions = true;};
  wrongType = refused {clipboard.max_entries = "lots";};
}
