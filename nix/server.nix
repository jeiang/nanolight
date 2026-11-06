{
  lib,
  stdenv,
  callPackage,
}: let
  source = callPackage ./source.nix {};
in
  stdenv.mkDerivation {
    pname = "nanolight-server";
    inherit (source) version src;

    nativeBuildInputs = [source.zig.hook];

    # Only the `server` step: the client is not built.
    dontUseZigBuild = true;
    dontUseZigInstall = true;
    postConfigure = source.seedZigDeps;
    installPhase = ''
      runHook preInstall
      zig build server -j$NIX_BUILD_CORES "$zigDefaultCpuFlag" "$zigDefaultOptimizeFlag" --prefix $out
      runHook postInstall
    '';

    meta = {
      description = "Sync server for Nanolight";
      license = lib.licenses.mit;
      mainProgram = "nanolight-server";
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  }
