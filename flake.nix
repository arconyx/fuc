{
  # I'd prefer nixpkgs-unstable but rebar3 is currently broken there
  # It's fixed, we're just waiting on hydra to catch up
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

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
