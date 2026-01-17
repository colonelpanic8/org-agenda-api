{
  description = "JSON HTTP API for org-agenda";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    emacs-overlay = {
      url = "github:nix-community/emacs-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-sync-rs = {
      url = "github:colonelpanic8/git-sync-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, emacs-overlay, git-sync-rs }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ emacs-overlay.overlay ];
        };

        # Git commit hash for version tracking
        # Uses clean rev if available, otherwise dirtyRev for uncommitted changes
        gitCommit = if (self ? rev) then self.rev else self.dirtyRev or "unknown";

        # Emacs with required packages (base packages from nix)
        emacsWithPackages = pkgs.emacs-nox.pkgs.withPackages (epkgs: [
          epkgs.simple-httpd
        ]);

        # Python with test dependencies
        pythonWithPackages = pkgs.python3.withPackages (ppkgs: [
          ppkgs.pytest
          ppkgs.requests
          ppkgs.pytest-timeout
        ]);

        # git-sync-rs from flake (with tests disabled to avoid sandbox issues)
        gitSyncRs = git-sync-rs.packages.${system}.default.overrideAttrs (old: {
          doCheck = false;
        });

        # The elisp files
        orgAgendaApiEl = ./org-agenda-api.el;
        containerInitEl = ./container-init.el;
        containerBootstrapEl = ./container-bootstrap.el;

        # Import the container builder
        mkContainer = import ./container.nix {
          inherit pkgs emacsWithPackages gitSyncRs orgAgendaApiEl containerInitEl gitCommit;
        };

        # Package an existing emacs config directory (with pre-populated straight/)
        # The straight/ directory should already have packages installed
        # Usage: mkEmacsConfig { emacsConfigDir = ./path/to/emacs.d; packages = [...]; }
        # packages: list of package names to include (default includes org essentials)
        mkEmacsConfig = {
          emacsConfigDir,
          packages ? [
            # Core
            "straight.el" "melpa" "gnu-elpa-mirror" "use-package" "bind-key" "dash.el"
            # Org ecosystem
            "org" "org-agenda-api" "org-bullets" "org-project-capture" "org-ql"
            "org-super-agenda" "org-wild-notifier.el" "org-window-habit"
            # Dependencies
            "s.el" "f.el" "ht.el" "ts.el" "peg" "compat" "transient" "magit" "with-editor"
            "org-roam" "emacsql" "emacsql-sqlite-builtin"
          ]
        }:
          pkgs.runCommand "emacs-config" {} ''
            mkdir -p $out

            # Copy elisp files
            for f in ${emacsConfigDir}/*.el; do
              if [ -f "$f" ]; then
                cp "$f" $out/
              fi
            done

            # Copy only needed packages from straight/
            if [ -d "${emacsConfigDir}/straight" ]; then
              mkdir -p $out/straight/repos $out/straight/build

              # Copy repos
              for pkg in ${pkgs.lib.concatStringsSep " " packages}; do
                if [ -d "${emacsConfigDir}/straight/repos/$pkg" ]; then
                  cp -rL --no-preserve=mode "${emacsConfigDir}/straight/repos/$pkg" $out/straight/repos/ 2>/dev/null || true
                fi
              done

              # Copy build directories
              for pkg in ${pkgs.lib.concatStringsSep " " packages}; do
                # Build dirs don't have .el suffix
                build_name=$(echo "$pkg" | sed 's/\.el$//')
                if [ -d "${emacsConfigDir}/straight/build/$build_name" ]; then
                  cp -rL --no-preserve=mode "${emacsConfigDir}/straight/build/$build_name" $out/straight/build/ 2>/dev/null || true
                fi
              done

              # Copy essential straight.el files
              cp "${emacsConfigDir}/straight/build-cache.el" $out/straight/ 2>/dev/null || true
              cp "${emacsConfigDir}/straight/repos.el" $out/straight/ 2>/dev/null || true
            fi
          '';

        # Bootstrap script to populate straight.el packages
        # Run this outside the Nix sandbox to download packages
        bootstrapScript = pkgs.writeShellScriptBin "bootstrap-emacs-config" ''
          set -e

          CONFIG_DIR="''${1:-$HOME/.emacs.d}"

          if [ ! -d "$CONFIG_DIR" ]; then
            echo "Error: Config directory does not exist: $CONFIG_DIR"
            echo "Usage: bootstrap-emacs-config [CONFIG_DIR]"
            exit 1
          fi

          echo "Bootstrapping Emacs config at: $CONFIG_DIR"
          echo "This will download packages via straight.el..."
          echo ""

          # Copy the bootstrap file to the config dir temporarily
          BOOTSTRAP_FILE=$(mktemp)
          cat > "$BOOTSTRAP_FILE" << 'ELISP'
          ${builtins.readFile ./container-bootstrap.el}
          ELISP

          # Ensure trailing slash on config dir
          CONFIG_DIR="''${CONFIG_DIR%/}/"

          # Run emacs in batch mode to trigger package downloads
          EMACS_CONFIG_DIR="$CONFIG_DIR" ${emacsWithPackages}/bin/emacs \
            --batch \
            --eval "(setq user-emacs-directory \"$CONFIG_DIR\")" \
            -l "$BOOTSTRAP_FILE" \
            2>&1 | tee /tmp/emacs-bootstrap.log

          rm -f "$BOOTSTRAP_FILE"

          echo ""
          echo "Bootstrap complete!"
          echo "The straight/ directory should now be populated at: $CONFIG_DIR/straight/"
          echo ""
          echo "You can now build a container with this config using:"
          echo "  nix build .#containerWithConfig --override-input emacsConfig path:$CONFIG_DIR"
        '';

      in {
        # Expose builder functions
        lib = { inherit mkContainer mkEmacsConfig; };

        packages = {
          # The elisp package
          org-agenda-api-el = pkgs.runCommand "org-agenda-api-el" {} ''
            mkdir -p $out/share/emacs/site-lisp
            cp ${orgAgendaApiEl} $out/share/emacs/site-lisp/org-agenda-api.el
          '';

          # Default Docker container image (minimal, no custom config)
          container = mkContainer {};

          # Bootstrap script for populating straight.el packages
          bootstrap-emacs-config = bootstrapScript;
        };

        # App to run the bootstrap script
        apps.bootstrap-emacs-config = {
          type = "app";
          program = "${bootstrapScript}/bin/bootstrap-emacs-config";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            emacsWithPackages
            pythonWithPackages
            pkgs.curl
            pkgs.jq
          ];

          shellHook = ''
            echo "org-agenda-api dev shell"
            echo "  emacs: $(emacs --version | head -1)"
            echo "  python: $(python --version)"
            echo ""
            echo "Commands:"
            echo "  pytest tests/          # Run integration tests"
            echo "  pytest tests/ -v       # Verbose output"
            echo "  pytest tests/ -x       # Stop on first failure"
            echo ""
            echo "Container (minimal):"
            echo "  nix build .#container  # Build container image"
            echo "  docker load < result   # Load into docker"
            echo ""
            echo "Container with custom Emacs config (straight.el):"
            echo "  # Step 1: Bootstrap packages (run outside Nix sandbox)"
            echo "  nix run .#bootstrap-emacs-config /path/to/emacs.d"
            echo ""
            echo "  # Step 2: Build container with your config"
            echo "  # In your own flake.nix:"
            echo "  #   container = org-agenda-api.lib.\${system}.mkContainer {"
            echo "  #     emacsConfigDir = ./path/to/emacs.d;"
            echo "  #     emacsConfigEntryPoint = \"org-config.el\";"
            echo "  #   };"
            echo ""
            echo "Run with existing org directory:"
            echo "  docker run -p 8080:80 -v /path/to/org:/data/org org-agenda-api"
            echo ""
            echo "Run with git repo (SSH key as file):"
            echo "  docker run -p 8080:80 \\"
            echo "    -e GIT_SYNC_REPOSITORY=git@github.com:user/org-files.git \\"
            echo "    -v /path/to/your/ssh_key:/secrets/ssh_key:ro \\"
            echo "    org-agenda-api"
            echo ""
            echo "Environment variables:"
            echo "  GIT_SYNC_REPOSITORY  - Git repo URL to clone on startup"
            echo "  GIT_SYNC_INTERVAL    - Sync interval in seconds (default: 60)"
            echo "  GIT_SYNC_NEW_FILES   - Include untracked files (default: true)"
            echo "  GIT_SSH_PRIVATE_KEY  - SSH private key content (alternative to mounting)"
            echo "  GIT_USER_EMAIL       - Git user email for commits"
            echo "  GIT_USER_NAME        - Git user name for commits"
            echo "  ORG_AGENDA_FILES     - Colon-separated list of org file paths"
            echo "  ORG_INBOX_FILE       - Path for new captures (default: /data/org/inbox.org)"
          '';
        };
      }
    );
}
