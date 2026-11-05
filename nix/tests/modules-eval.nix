# Evaluates the client and server modules. The NixOS modules are checked in a
# real system; nix-darwin and home-manager are not inputs, so their modules run
# against stand-ins for the few options they set (checks the module logic, not
# that those options exist upstream).
{
  self,
  nixpkgs,
  pkgs,
}: let
  lib = nixpkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;

  nixos = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.default
      self.nixosModules.server
      {
        programs.nanolight = {
          enable = true;
          settings = {
            hotkey = "opt_space";
            quicklinks = [
              {
                name = "DuckDuckGo";
                url = "https://duckduckgo.com/?q={argument}";
                keyword = "ddg";
              }
            ];
            sync = {
              url = "http://127.0.0.1:8890";
              token_file = "/run/secrets/nanolight-token";
            };
          };
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
      systemd.user.services = lib.mkOption {type = lib.types.attrsOf lib.types.raw;};
      launchd.agents = lib.mkOption {type = lib.types.attrsOf lib.types.raw;};
    };
  };

  evalStub = module: modules:
    lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [stubs module] ++ modules;
    };

  settings = {hotkey = "cmd_space";};

  darwin = evalStub self.darwinModules.default [
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
  home = evalStub self.homeManagerModules.default [
    {
      xdg.configHome = "/home/jane/.config";
      programs.nanolight = {
        enable = true;
        inherit settings;
      };
    }
  ];

  agent = darwin.config.launchd.user.agents.nanolight.serviceConfig;
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
  };
in
  assert lib.assertMsg (lib.all lib.id (lib.attrValues facts)) "module eval: ${builtins.toJSON facts}";
    pkgs.runCommand "modules-eval" {} ''
      echo ${builtins.unsafeDiscardStringContext nixos.config.system.build.toplevel.drvPath} > $out
    ''
