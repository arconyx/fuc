{
  # I'd prefer nixpkgs-unstable but rebar3 is currently broken there
  # It's fixed on master
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";

  outputs =
    { nixpkgs, ... }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
    in
    {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = with pkgs; [
          gleam
          erlang_27
          beam27Packages.rebar3
          litecli
        ];
      };
    };
}
