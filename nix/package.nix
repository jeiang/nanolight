{
  lib,
  stdenv,
  callPackage,
  zig_0_17,
  wrapGAppsHook3,
  gtk3,
  gdk-pixbuf,
  glib,
  cairo,
  libx11,
  libxfixes,
  libxtst,
  wayland,
  libglvnd,
}: let
  source = callPackage ./source.nix {};

  # Opened at run time with dlopen: nothing in the ELF's NEEDED list names them.
  dlopened = [gtk3 gdk-pixbuf glib cairo libx11 libxfixes libxtst wayland libglvnd];
in
  stdenv.mkDerivation {
    pname = "nanolight";
    inherit (source) version src;

    nativeBuildInputs =
      [zig_0_17.hook]
      ++ lib.optionals stdenv.hostPlatform.isLinux [wrapGAppsHook3];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux dlopened;

    zigBuildFlags = ["-Dnix=true" "-Dversion=${source.version}"];
    zigCheckFlags = ["-Dnix=true"];
    doCheck = true;

    postConfigure = source.seedZigDeps;

    preFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
      gappsWrapperArgs+=(--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath dlopened})
    '';

    postInstall = lib.optionalString stdenv.hostPlatform.isDarwin ''
      mkdir -p $out/Applications
      mv $out/Nanolight.app $out/Applications/
      ln -sf $out/Applications/Nanolight.app/Contents/MacOS/nanolight $out/bin/nanolight
    '';

    meta = {
      description = "A launcher for macOS, Linux and Windows, drawn by nanoui";
      license = lib.licenses.mit;
      mainProgram = "nanolight";
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  }
