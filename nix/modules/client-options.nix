# The `programs.nanolight` options every client module (NixOS, nix-darwin,
# home-manager) shares.
self: {
  lib,
  pkgs,
  ...
}: let
  toml = pkgs.formats.toml {};
in {
  options.programs.nanolight = {
    enable = lib.mkEnableOption "Nanolight, a launcher";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.nanolight;
      defaultText = lib.literalExpression "nanolight.packages.\${system}.nanolight";
      description = "The Nanolight package (a Nix build: no updater, no login-item UI).";
    };
    settings = lib.mkOption {
      inherit (toml) type;
      default = {};
      example = lib.literalExpression ''
        {
          hotkey = "cmd_space";
          sync = {
            url = "http://100.64.0.1:8890";
            token_file = "/run/secrets/nanolight-token";
          };
        }
      '';
      description = "Written as config.toml. In-app changes win over it; see the README for the keys.";
    };
  };
}
