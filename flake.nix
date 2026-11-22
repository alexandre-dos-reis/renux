{
  description = "Renux, a native Linux client for Rex";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # `self.submodules` is ignored for `github:` refs (NixOS/nix#13571), so Ghostty is its own input.
  # Keep this revision at the third_party/ghostty gitlink; `nix develop` warns when they differ.
  inputs.ghostty = {
    url = "github:ghostty-org/ghostty/e95bed63330cc921f3cf2fe3d14e024396b09d43";
    flake = false;
  };

  outputs = { self, nixpkgs, ghostty }:
    let
      forLinux = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
      version = builtins.head (builtins.match ".*\n    \\.version = \"([^\"]+)\".*" (builtins.readFile ./build.zig.zon));
    in {
      packages = forLinux (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in rec {
          default = renux;
          renux = pkgs.stdenv.mkDerivation {
            pname = "renux";
            inherit version;
            src = self;
            postPatch = ''
              mkdir -p third_party
              rm -rf third_party/ghostty
              ln -s ${ghostty} third_party/ghostty
            '';
            nativeBuildInputs = with pkgs; [ zig_0_17 pkg-config wrapGAppsHook4 ];
            buildInputs = with pkgs; [ gtk4 libadwaita librsvg poppler libepoxy fontconfig ];
            # Ghostty's package set also provides gobject; build.zig.zon must keep Ghostty's URL and hash.
            zigBuildFlags = [ "--system" "${pkgs.callPackage (ghostty + "/deps/packages.nix") {}}" "-Doptimize=ReleaseFast" ];
            meta = {
              description = "Native Linux client for Rex";
              homepage = "https://github.com/zenodea/renux";
              license = pkgs.lib.licenses.asl20;
              platforms = pkgs.lib.platforms.linux;
              mainProgram = "renux";
            };
          };
        });
      devShells = forLinux (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          inputsFrom = [ self.packages.${system}.renux ];
          shellHook = ''
            if gitlink=$(git rev-parse -q --verify HEAD:third_party/ghostty 2>/dev/null) && [ "$gitlink" != ${ghostty.rev} ]; then
              echo "warning: flake.nix pins Ghostty ${ghostty.rev}, but the third_party/ghostty gitlink is $gitlink" >&2
            fi
          '';
        };
      });
    };
}
