self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nanolight-server;
  host =
    if lib.hasInfix ":" cfg.listenAddress
    then "[${cfg.listenAddress}]"
    else cfg.listenAddress;
in {
  options.services.nanolight-server = {
    enable = lib.mkEnableOption "the Nanolight sync server";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.nanolight-server;
      defaultText = lib.literalExpression "nanolight.packages.\${system}.nanolight-server";
      description = "The nanolight-server package.";
    };
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "The address to listen on. The server speaks plain HTTP: bind a private address or put a TLS proxy in front.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8890;
      description = "The TCP port to listen on.";
    };
    tokensFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        A file of `account:sha256hex(token)` lines (`nanolight-server hash-token`
        prints one). Read through a systemd credential, so it may be root-only,
        such as a sops-nix secret path. Do not use a path in the Nix store for real tokens.
      '';
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the port in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [cfg.port];

    systemd.services.nanolight-server = {
      description = "Nanolight sync server";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} serve --listen ${host}:${toString cfg.port} --state %S/nanolight --tokens %d/tokens";
        LoadCredential = "tokens:${cfg.tokensFile}";
        DynamicUser = true;
        StateDirectory = "nanolight";
        StateDirectoryMode = "0700";
        Restart = "on-failure";

        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service" "~@privileged"];
        UMask = "0077";
      };
    };
  };
}
