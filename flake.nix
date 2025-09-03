{
  description = "A basic flake with a shell";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.systems.url = "github:nix-systems/default";
  inputs.flake-utils = {
    url = "github:numtide/flake-utils";
    inputs.systems.follows = "systems";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        gems = pkgs.bundlerEnv {
          name = "cpap-gems";
          ruby = pkgs.ruby_3_4;
          gemdir = ./.;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            pkgs.bashInteractive
            gems
            (lowPrio gems.wrappedRuby)
            (bundix.override {
              bundler = bundler.override {
                ruby = gems.ruby;
              };
            })

          ];
        };
      }
    );
}
