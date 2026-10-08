{
  description = "aside.nvim development shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.neovim pkgs.tmux ];
          # test/init_minimal.lua prepends this to the runtimepath for mini.test.
          MINI_PATH = "${pkgs.vimPlugins.mini-nvim}";
        };
      });
    };
}
