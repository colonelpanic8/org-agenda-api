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
    {
      # NixOS modules
      nixosModules.default = import ./org-agenda-api.nix;
      nixosModules.org-agenda-api = import ./org-agenda-api.nix;
    }
    //
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ emacs-overlay.overlay ];
        };

        # Emacs with required packages
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

        # Import the container builder
        mkContainer = import ./container.nix {
          inherit pkgs emacsWithPackages gitSyncRs orgAgendaApiEl containerInitEl;
        };

      in {
        # Expose mkContainer as a lib function
        lib = { inherit mkContainer; };

        packages = {
          # The elisp package
          org-agenda-api-el = pkgs.runCommand "org-agenda-api-el" {} ''
            mkdir -p $out/share/emacs/site-lisp
            cp ${orgAgendaApiEl} $out/share/emacs/site-lisp/org-agenda-api.el
          '';

          # Default Docker container image
          container = mkContainer {};
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
            echo "Container:"
            echo "  nix build .#container  # Build container image"
            echo "  docker load < result   # Load into docker"
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
