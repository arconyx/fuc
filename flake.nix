{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      forEachSystem =
        f: lib.genAttrs [ "aarch64-linux" "x86_64-linux" ] (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            gleam
            beamPackages.erlang
            beamPackages.rebar3
            litecli
          ];
        };
      });
      packages = forEachSystem (pkgs: {
        default = pkgs.callPackage ./package.nix { };
      });
      nixosModules.default = {
        imports = [ ./module.nix ];
      };
    };
}
