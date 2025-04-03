{
  description = "MCP to interface with pandoc to convert files to differnt formats. Eg: Converting markdown to pdf.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pyproject-nix = {
      url = "github:nix-community/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:adisbladis/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        nixpkgs.follows = "nixpkgs";
      };
    };
    uv2nix_hammer_overrides = {
      url = "github:TyberiusPrime/uv2nix_hammer_overrides";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    systems,
    nixpkgs,
    flake-utils,
    pyproject-nix,
    uv2nix,
    pyproject-build-systems,
    uv2nix_hammer_overrides,
    ...
  } @ inputs:
    flake-utils.lib.eachDefaultSystem (system: let
      inherit (nixpkgs) lib;

      workspace = uv2nix.lib.workspace.loadWorkspace {workspaceRoot = ./.;};

      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel"; # or sourcePreference = "sdist";
      };

      hammer-overrides = uv2nix_hammer_overrides.overrides pkgs;

      pyprojectOverrides = pkgs.lib.composeManyExtensions [
        hammer-overrides
      ];

      python = pkgs.python312;

      pythonSet = (
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        })
        .overrideScope (lib.composeManyExtensions [
          pyproject-build-systems.overlays.default
          overlay
          pyprojectOverrides
        ])
      );
      pkgs = import nixpkgs {
        inherit system;
        # config.allowUnfree = true;
        # config.cudaSupport = false;
      };
    in {
      formatter = pkgs.alejandra;

      devShells = {
        default = let
          editableOverlay = workspace.mkEditablePyprojectOverlay {
            root = "$REPO_ROOT";
          };
          editablePythonSets = pythonSet.overrideScope (
            lib.composeManyExtensions [
              editableOverlay

              (final: prev: {
                mcp-pandoc = prev.mcp-pandoc.overrideAttrs (old: {
                  src = lib.fileset.toSource {
                    root = old.src;
                    fileset = lib.fileset.unions (map (file: old.src + file) [
                      "/pyproject.toml"
                      "/README.md"
                      "/src/mcp_pandoc"
                    ]);
                  };
                  nativeBuildInputs =
                    old.nativeBuildInputs
                    ++ final.resolveBuildSystem {
                      editables = [];
                    };
                });
              })
            ]
          );

          virtualenv = (editablePythonSets.mkVirtualEnv "mcp-pandoc" workspace.deps.all).overrideAttrs (old: {});
        in
          pkgs.mkShell {
            packages = with pkgs; [
              uv
              virtualenv
              # pandoc
              nodejs_23
              # Define custom commands as packages
              (writeScriptBin "mcp-inspector" ''
                #!${bash}/bin/bash
                ${nodejs_23}/bin/npx -y @modelcontextprotocol/inspector nix run
              '')
            ];

            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON = "${virtualenv}/bin/python";
              UV_PYTHON_DOWNLOADS = "never";
            };

            shellHook = ''
              unset PYTHONPATH
              export REPO_ROOT=$(git rev-parse --show-toplevel)
            '';
          };
      };

      packages = {
        default = (pythonSet.mkVirtualEnv "mcp-pandoc" workspace.deps.default).overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.makeWrapper];
          postFixup = ''
            wrapProgram $out/bin/mcp-pandoc \
              --prefix PATH : ${pkgs.lib.makeBinPath [pkgs.pandoc]}
          '';
        });
      };
    });
}
