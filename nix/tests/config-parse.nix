# Reads the config.toml each client module writes with Nanolight's own parser
# (`zig build check-config`), so a key the app would refuse or ignore fails the
# flake instead of falling back to the defaults at run time. The tool must also
# refuse a misspelled key and a wrongly typed value.
{
  self,
  nixpkgs,
  pkgs,
}: let
  lib = nixpkgs.lib;
  evals = import ./evals.nix {inherit self nixpkgs pkgs;};
  source = pkgs.callPackage ../source.nix {};
  written = [
    evals.nixos.config.environment.etc."nanolight/config.toml".source
    evals.darwin.config.environment.etc."nanolight/config.toml".source
    evals.home.config.xdg.configFile."nanolight/config.toml".source
  ];
  refused = [evals.misspelledKey evals.wrongType];
in
  pkgs.stdenv.mkDerivation {
    pname = "nanolight-config-parse";
    inherit (source) version src;

    nativeBuildInputs = [source.zig.hook];

    dontUseZigBuild = true;
    dontUseZigInstall = true;
    postConfigure = source.seedZigDeps;
    buildPhase = ''
      runHook preBuild
      zig build check-config -j$NIX_BUILD_CORES "$zigDefaultCpuFlag" --prefix tool
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      tool/bin/nanolight-check-config ${lib.escapeShellArgs written}
      for f in ${lib.escapeShellArgs refused}; do
        if tool/bin/nanolight-check-config "$f"; then
          echo "$f: accepted, but the app would not take all of it" >&2
          exit 1
        fi
      done
      touch $out
      runHook postInstall
    '';
  }
