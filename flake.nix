{
  description = "Nanolight, a launcher for macOS, Linux and Windows, drawn by nanoui";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    forSystems = systems: f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    linux = lib.filter (lib.hasSuffix "-linux") systems;
  in {
    packages = forSystems systems (pkgs: rec {
      nanolight = pkgs.callPackage ./nix/package.nix {};
      nanolight-server = pkgs.callPackage ./nix/server.nix {};
      default = nanolight;
    });

    nixosModules = {
      default = import ./nix/modules/nixos.nix self;
      server = import ./nix/modules/server.nix self;
    };
    darwinModules.default = import ./nix/modules/darwin.nix self;
    homeManagerModules.default = import ./nix/modules/home-manager.nix self;

    checks = forSystems linux (pkgs: {
      nanolight = self.packages.${pkgs.stdenv.hostPlatform.system}.nanolight;
      nanolight-server = self.packages.${pkgs.stdenv.hostPlatform.system}.nanolight-server;
      server-vm = import ./nix/tests/server-vm.nix {inherit self pkgs;};
      modules-eval = import ./nix/tests/modules-eval.nix {inherit self nixpkgs pkgs;};
      config-parse = import ./nix/tests/config-parse.nix {inherit self nixpkgs pkgs;};
    });

    # The Zig of build.zig.zon, with editor language servers for its Zig and Nix.
    devShells = forSystems systems (pkgs: let
      source = pkgs.callPackage ./nix/source.nix {};
    in {
      default = pkgs.mkShellNoCC {
        packages = [source.zig source.zls pkgs.nixd pkgs.alejandra];
      };
    });

    formatter = forSystems systems (pkgs: pkgs.alejandra);
  };
}
