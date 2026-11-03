{
  lib,
  stdenv,
  callPackage,
  zig_0_17,
  wrapGAppsHook3,
  patchelf,
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
      ++ lib.optionals stdenv.hostPlatform.isLinux [wrapGAppsHook3 patchelf];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux dlopened;

    zigBuildFlags = ["-Dnix=true" "-Dversion=${source.version}"];
    zigCheckFlags = ["-Dnix=true"];
    doCheck = true;

    postConfigure = source.seedZigDeps;

    # An rpath, not LD_LIBRARY_PATH: the launcher's children must not inherit the store's libraries.
    # It is added after fixup, whose patchelf pass would shrink it away, and onto the wrapped binary.
    postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
      patchelf --add-rpath ${lib.makeLibraryPath dlopened} $out/bin/.nanolight-wrapped
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
