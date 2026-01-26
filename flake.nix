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
    mova = {
      url = "github:colonelpanic8/mova";
      flake = false;
    };
    org-window-habit = {
      url = "github:colonelpanic8/org-window-habit";
      flake = false;
    };
    org-project-capture = {
      url = "github:colonelpanic8/org-project-capture";
      flake = false;
    };
    org-wild-notifier = {
      url = "github:emacsorphanage/org-wild-notifier";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, emacs-overlay, git-sync-rs, mova, org-window-habit, org-project-capture, org-wild-notifier }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ emacs-overlay.overlay ];
        };

        # Git commit hash for version tracking
        # Uses clean rev if available, otherwise dirtyRev for uncommitted changes
        gitCommit = if (self ? rev) then self.rev else self.dirtyRev or "unknown";

        # Mova git commit from flake input
        movaGitCommit = mova.rev or "unknown";

        # org-window-habit package built from flake input
        orgWindowHabitPkg = pkgs.emacs-nox.pkgs.trivialBuild {
          pname = "org-window-habit";
          version = "0.1.0";
          src = org-window-habit;
          # org-window-habit depends on org
          buildInputs = [ pkgs.emacs-nox.pkgs.org ];
        };

        # org-category-capture package (part of org-project-capture repo)
        # Skip byte-compilation to avoid dependency issues, just install the .el file
        orgCategoryCapturePkg = pkgs.runCommand "emacs-org-category-capture" {} ''
          mkdir -p $out/share/emacs/site-lisp
          cp ${org-project-capture}/org-category-capture.el $out/share/emacs/site-lisp/
        '';

        # org-project-capture package built from flake input
        # Skip byte-compilation to avoid dependency issues, just install the .el files
        orgProjectCapturePkg = pkgs.runCommand "emacs-org-project-capture" {} ''
          mkdir -p $out/share/emacs/site-lisp
          cp ${org-project-capture}/org-project-capture.el $out/share/emacs/site-lisp/
          cp ${org-project-capture}/org-project-capture-backend.el $out/share/emacs/site-lisp/
        '';

        # org-wild-notifier package built from flake input
        orgWildNotifierPkg = pkgs.runCommand "emacs-org-wild-notifier" {} ''
          mkdir -p $out/share/emacs/site-lisp
          cp ${org-wild-notifier}/org-wild-notifier.el $out/share/emacs/site-lisp/
        '';

        # Emacs with required packages (base packages from nix)
        emacsWithPackages = pkgs.emacs-nox.pkgs.withPackages (epkgs: [
          epkgs.simple-httpd
          epkgs.org
          epkgs.dash
          epkgs.s
          epkgs.async  # required by alert
          epkgs.alert  # required by org-wild-notifier
          orgWindowHabitPkg
          orgCategoryCapturePkg
          orgProjectCapturePkg
          orgWildNotifierPkg
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

        # Node.js for building mova
        nodejs = pkgs.nodejs_22;

        # Mova package info
        movaPackageJson = builtins.fromJSON (builtins.readFile "${mova}/package.json");

        # Mova node_modules built with mkYarnModules
        movaNodeModules = pkgs.mkYarnModules {
          pname = movaPackageJson.name;
          version = movaPackageJson.version;
          inherit nodejs;
          packageJSON = "${mova}/package.json";
          yarnLock = "${mova}/yarn.lock";
          offlineCache = pkgs.fetchYarnDeps {
            name = "mova-deps-offline-cache";
            yarnLock = "${mova}/yarn.lock";
            hash = "sha256-frZDiP2uXYok+HoVzHf5PYQu6qARKwG+8WWXVsgIci4=";
          };
        };

        # Mova web build
        movaWeb = pkgs.stdenv.mkDerivation {
          pname = "mova-web";
          version = movaPackageJson.version;

          src = mova;

          nativeBuildInputs = [
            pkgs.yarn
            nodejs
          ];

          buildPhase = ''
            runHook preBuild

            # Set HOME for Expo cache
            export HOME=$(pwd)

            # Set mova git commit for version tracking
            export MOVA_GIT_COMMIT=${movaGitCommit}

            # Copy prebuilt node_modules
            cp -r ${movaNodeModules}/node_modules ./node_modules

            # Create cache directory
            mkdir -p .cache

            # Build web export
            yarn --offline expo export --platform web

            runHook postBuild
          '';

          installPhase = ''
            mkdir -p $out
            cp -r dist/* $out/
          '';
        };

        # The elisp files
        containerInitEl = ./container-init.el;
        containerBootstrapEl = ./container-bootstrap.el;

        # Package all org-agenda-api elisp files into a site-lisp directory
        # Must explicitly name destination files to avoid nix store hash prefixes
        orgAgendaApiSitelisp = pkgs.runCommand "org-agenda-api-sitelisp" {} ''
          mkdir -p $out/share/emacs/site-lisp
          cp ${./org-agenda-api.el} $out/share/emacs/site-lisp/org-agenda-api.el
          cp ${./org-agenda-api-core.el} $out/share/emacs/site-lisp/org-agenda-api-core.el
          cp ${./org-agenda-api-data.el} $out/share/emacs/site-lisp/org-agenda-api-data.el
          cp ${./org-agenda-api-capture.el} $out/share/emacs/site-lisp/org-agenda-api-capture.el
          cp ${./org-agenda-api-mutations.el} $out/share/emacs/site-lisp/org-agenda-api-mutations.el
          cp ${./org-agenda-api-endpoints.el} $out/share/emacs/site-lisp/org-agenda-api-endpoints.el
          cp ${./org-agenda-api-categories.el} $out/share/emacs/site-lisp/org-agenda-api-categories.el
          cp ${./org-agenda-api-window-habit.el} $out/share/emacs/site-lisp/org-agenda-api-window-habit.el
        '';

        # Import the container builder
        mkContainer = import ./container.nix {
          inherit pkgs emacsWithPackages gitSyncRs orgAgendaApiSitelisp containerInitEl gitCommit movaWeb;
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
          # The elisp package (all modules)
          org-agenda-api-el = orgAgendaApiSitelisp;

          # Mova web app build
          inherit movaWeb;

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
            pkgs.just
            pkgs.ruff
          ];

          shellHook = ''
            echo "org-agenda-api dev shell"
            echo "  emacs: $(emacs --version | head -1)"
            echo "  python: $(python --version)"
            echo "  ruff: $(ruff --version)"
            echo ""
            echo "Commands:"
            echo "  pytest tests/          # Run integration tests"
            echo "  pytest tests/ -v       # Verbose output"
            echo "  pytest tests/ -x       # Stop on first failure"
            echo ""
            echo "Linting:"
            echo "  ruff check tests/      # Lint Python test files"
            echo "  ruff format --check tests/  # Check Python formatting"
            echo "  emacs --batch -f batch-byte-compile org-agenda-api.el  # Byte-compile elisp"
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
          '';
        };

        # Checks run by `nix flake check`
        # Note: Integration tests (pytest) are run separately via `nix develop -c pytest`
        # because they need localhost networking which doesn't work in the Nix sandbox
        checks = {
          # Elisp byte-compilation check
          elisp-compile = pkgs.stdenv.mkDerivation {
            name = "org-agenda-api-elisp-compile";
            src = ./.;

            nativeBuildInputs = [ emacsWithPackages ];

            buildPhase = ''
              export HOME=$(mktemp -d)

              # Byte-compile all elisp files
              for f in *.el; do
                echo "Compiling $f..."
                emacs --batch \
                  -L . \
                  -f batch-byte-compile "$f" || exit 1
              done
            '';

            installPhase = ''
              mkdir -p $out
              cp *.elc $out/ 2>/dev/null || true
              echo "Elisp compilation passed" > $out/result
            '';
          };

          # Python linting with ruff
          ruff = pkgs.stdenv.mkDerivation {
            name = "org-agenda-api-ruff";
            src = ./.;

            nativeBuildInputs = [ pkgs.ruff ];

            buildPhase = ''
              ruff check tests/
              ruff format --check tests/
            '';

            installPhase = ''
              mkdir -p $out
              echo "Ruff checks passed" > $out/result
            '';
          };
        };
      }
    );
}
