{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      forEachSystem =
        f: lib.genAttrs lib.systems.flakeExposed (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            gleam
            erlang_27
            beam27Packages.rebar3
            litecli
          ];
        };
      });
      packages = forEachSystem (pkgs: {
        default = pkgs.callPackage ./package.nix { };
      });
      nixosModules.default = import ./module.nix;
    };
}
