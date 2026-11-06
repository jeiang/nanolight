# What `zig build` reads, the Zig it needs, and its dependencies, all as
# build.zig.zon says (its .paths, .minimum_zig_version and .dependencies).
{
  lib,
  pkgs,
  fetchgit,
}: let
  zonLines = lib.splitString "\n" (builtins.readFile ../build.zig.zon);

  # The quoted value of the first `.<field> = "..."` in `lines`.
  zonString = field: lines:
    lib.pipe lines [
      (lib.findFirst (lib.hasInfix ".${field} = ") (throw "build.zig.zon has no .${field}"))
      (builtins.match ''.*"([^"]+)".*'')
      builtins.head
    ];

  # build.zig.zon from `.<name> = .{` on: the dependency's fields come first.
  dependencyLines = name:
    lib.drop
    (lib.lists.findFirstIndex (lib.hasInfix ".${name} = .{") (throw "build.zig.zon has no .${name}") zonLines)
    zonLines;

  # `git+<url>#<rev>`, as `zig fetch --save` writes it.
  nanouiLines = dependencyLines "nanoui";
  nanouiUrl = builtins.match "git\\+(.*)#(.*)" (zonString "url" nanouiLines);

  # Each name is the package hash from the .zon: Zig finds a package by it.
  zigDeps = {
    ${zonString "hash" nanouiLines} = fetchgit {
      url = builtins.elemAt nanouiUrl 0;
      rev = builtins.elemAt nanouiUrl 1;
      # Zig fetches a package without its submodules; nanoui has several.
      fetchSubmodules = false;
      # Nix's own hash of the checkout: a new nanoui pin needs a new one.
      hash = "sha256-+lyZnQXwswPApJzkV1aZPJK+4MLbqK7ieD9cMvPITIw=";
    };
    # nanoui's dependency, pinned in nanoui's build.zig.zon (not this one's).
    "http_zig-0.1.0-2CB7E00SAwAnwnBkJDgCDm3zLwrCmZZkHNSw5t7X9Vbf" = fetchgit {
      url = "https://github.com/justrach/http-zig";
      rev = "1f798e762f52ff81cc6c370b4f322c9e65064462";
      fetchSubmodules = false;
      hash = "sha256-BQNqFYQlxTiXSQBBEgaRC5UiJUd2KOE2tsEQt6y9LCY=";
    };
  };

  # `.paths = .{ "build.zig", ... }`, on its one line.
  paths = lib.pipe zonLines [
    (lib.findFirst (lib.hasInfix ".paths = ") (throw "build.zig.zon has no .paths"))
    (builtins.split ''"([^"]+)"'')
    (lib.filter builtins.isList)
    (map builtins.head)
  ];

  zigVersion = lib.splitString "." (zonString "minimum_zig_version" zonLines);
in {
  version = zonString "version" zonLines;

  # nixpkgs' Zig of build.zig.zon's minimum_zig_version (zig_0_17 for 0.17.0).
  zig = pkgs."zig_${builtins.elemAt zigVersion 0}_${builtins.elemAt zigVersion 1}";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions (map (path: ../. + "/${path}") paths);
  };

  # Zig finds a fetched package as zig-pkg/<hash>; the sandbox has no network
  # for it to fetch, so the pinned sources are put there.
  seedZigDeps = ''
    mkdir -p zig-pkg
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: dep: "cp -r ${dep} zig-pkg/${name}") zigDeps)}
    chmod -R u+w zig-pkg
  '';
}
