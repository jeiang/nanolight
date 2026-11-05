# What `zig build` reads (build.zig.zon's .paths), and the Zig dependencies
# at the revisions build.zig.zon pins (nanoui's own build.zig.zon pins http_zig).
{
  lib,
  fetchgit,
}: let
  # Each name is the package hash from the .zon: Zig finds a package by it.
  zigDeps = {
    "nanoui-0.12.0-we0KMa-SJAAVqwMpS2tGhq0-ptie65zdk8NOf2IQKBxR" = fetchgit {
      url = "https://github.com/justrach/nanoui";
      rev = "d1330a84fca9581cdcaff7fa71041b2cccf3066b";
      # Zig fetches a package without its submodules; nanoui has several.
      fetchSubmodules = false;
      hash = "sha256-+lyZnQXwswPApJzkV1aZPJK+4MLbqK7ieD9cMvPITIw=";
    };
    "http_zig-0.1.0-2CB7E00SAwAnwnBkJDgCDm3zLwrCmZZkHNSw5t7X9Vbf" = fetchgit {
      url = "https://github.com/justrach/http-zig";
      rev = "1f798e762f52ff81cc6c370b4f322c9e65064462";
      fetchSubmodules = false;
      hash = "sha256-BQNqFYQlxTiXSQBBEgaRC5UiJUd2KOE2tsEQt6y9LCY=";
    };
  };
in {
  version = lib.pipe (builtins.readFile ../build.zig.zon) [
    (lib.splitString "\n")
    (lib.findFirst (lib.hasInfix ".version = ") null)
    (builtins.match ''.*"([^"]+)".*'')
    builtins.head
  ];

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
      ../macos
      ../LICENSE
    ];
  };

  # Zig finds a fetched package as zig-pkg/<hash>; the sandbox has no network
  # for it to fetch, so the pinned sources are put there.
  seedZigDeps = ''
    mkdir -p zig-pkg
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: dep: "cp -r ${dep} zig-pkg/${name}") zigDeps)}
    chmod -R u+w zig-pkg
  '';
}
