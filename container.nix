{ pkgs, emacsWithPackages, gitSyncRs, orgAgendaApiSitelisp, containerInitEl, gitCommit ? "unknown", movaWeb, orgAgendaApiVersion ? "unknown" }:

let
  lib = pkgs.lib;
  port = 2025;

  # Nginx with headers-more module for clearing WWW-Authenticate header
  nginxWithModules = pkgs.nginx.override {
    modules = [ pkgs.nginxModules.moreheaders ];
  };

  # Path where config will be in the container
  containerConfigPath = "/emacs-config";
  orgAgendaApiLoadPathDefault = "/share/emacs/site-lisp";
  containerInitPath = "/etc/org-agenda-api/container-init.el";

  # Nginx config that proxies to emacs
  # Auth is configured dynamically via /tmp/nginx-auth.conf include
  nginxConf = pkgs.writeText "nginx.conf" ''
    # Run as nginx user
    user nginx nginx;
    daemon off;
    error_log /dev/stderr info;
    pid /tmp/nginx.pid;
    events {
      worker_connections 64;
    }
    http {
      include ${nginxWithModules}/conf/mime.types;
      default_type application/octet-stream;
      access_log /dev/stdout;
      client_body_temp_path /tmp/nginx_client_body;
      proxy_temp_path /tmp/nginx_proxy;
      fastcgi_temp_path /tmp/nginx_fastcgi;
      uwsgi_temp_path /tmp/nginx_uwsgi;
      scgi_temp_path /tmp/nginx_scgi;

      upstream emacs {
        server 127.0.0.1:${toString port};
      }

      server {
        listen 80;
        root /var/www/mova;

        # Health check endpoint - no auth required for monitoring tools
        location = /health {
          proxy_pass http://emacs;
          proxy_http_version 1.1;
          proxy_connect_timeout 5s;
          proxy_read_timeout 5s;
        }

        # Version endpoint - no auth required
        location = /version {
          # Handle preflight OPTIONS request
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Allow-Methods' '*' always;
            add_header 'Access-Control-Allow-Headers' '*' always;
            add_header 'Access-Control-Max-Age' 86400 always;
            add_header 'Content-Length' 0;
            add_header 'Content-Type' 'text/plain';
            return 204;
          }

          proxy_pass http://emacs;
          proxy_http_version 1.1;

          # CORS headers for actual requests
          add_header 'Access-Control-Allow-Origin' '*' always;
          add_header 'Access-Control-Allow-Methods' '*' always;
          add_header 'Access-Control-Allow-Headers' '*' always;
          add_header 'Access-Control-Expose-Headers' '*' always;
        }

        # API endpoints - proxy to emacs with auth
        # Support both /endpoint and /api/endpoint paths for backwards compatibility
        location ~ ^/(api/)?(agenda|agenda-files|get-all-todos|get-todays-agenda|complete|set-state|update|delete|delete-logbook-entry|reload|todo-states|todo-states-by-file|capture-templates|capture|custom-views|custom-view|debug-config|filter-options|metadata|restart|category-types|categories|category-tasks|category-capture|habit-config|habit-status|all-habit-statuses|notifications|trigger-sync|call-function|meta-score|meta-score-series|app-config(/[A-Za-z0-9_-]+)?|add-clock|update-clock)$ {
          # Handle preflight OPTIONS request (before auth check)
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Allow-Methods' '*' always;
            add_header 'Access-Control-Allow-Headers' '*' always;
            add_header 'Access-Control-Max-Age' 86400 always;
            add_header 'Content-Length' 0;
            add_header 'Content-Type' 'text/plain';
            return 204;
          }

          include /tmp/nginx-auth.conf;

          # Clear WWW-Authenticate header to prevent browser's native auth popup
          # JS handles 401 responses directly
          more_clear_headers 'WWW-Authenticate';

          # Strip /api prefix if present (backend only understands /endpoint paths)
          rewrite ^/api/(.*)$ /$1 break;

          proxy_pass http://emacs;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;

          # CORS headers for actual requests
          add_header 'Access-Control-Allow-Origin' '*' always;
          add_header 'Access-Control-Allow-Methods' '*' always;
          add_header 'Access-Control-Allow-Headers' '*' always;
          add_header 'Access-Control-Expose-Headers' '*' always;
        }

        # Static files - serve mova web app (no auth)
        location / {
          try_files $uri $uri/ /index.html;
        }
      }
    }
  '';

  # git-sync-rs configuration file (enables conflict_branch feature)
  gitSyncConfig = pkgs.writeText "git-sync-rs-config.toml" ''
    [defaults]
    sync_interval = 60
    sync_new_files = true
    skip_hooks = false
    commit_message = "changes from {hostname} on {timestamp}"
    remote = "origin"
    # Create fallback branch on merge conflicts instead of failing
    conflict_branch = true
  '';

  # Multi-repo git sync wrapper script
  gitSyncMultiScript = pkgs.writeShellScriptBin "git-sync-multi" ''
    PIDS=""

    cleanup() {
      echo "git-sync-multi: Stopping all git-sync processes..."
      for pid in $PIDS; do
        kill $pid 2>/dev/null || true
      done
      wait
      exit 0
    }

    trap cleanup SIGTERM SIGINT

    start_sync() {
      local repo_path="$1"
      echo "git-sync-multi: Starting sync for $repo_path"
      ${gitSyncRs}/bin/git-sync-rs watch -d "$repo_path" --config ${gitSyncConfig} &
      PIDS="$PIDS $!"
    }

    if [ -n "$GIT_SYNC_REPOSITORIES" ]; then
      echo "git-sync-multi: Multi-repo mode"
      PATHS=$(${pkgs.jq}/bin/jq -r '.[].path // empty' <<< "$GIT_SYNC_REPOSITORIES" 2>/dev/null)
      if [ -z "$PATHS" ]; then
        echo "git-sync-multi: ERROR - Failed to parse GIT_SYNC_REPOSITORIES JSON"
        exit 1
      fi
      for path in $PATHS; do
        repo_dir="/data/$path"
        if [ -d "$repo_dir/.git" ]; then
          start_sync "$repo_dir"
        else
          echo "git-sync-multi: WARNING - $repo_dir is not a git repository, skipping"
        fi
      done
    elif [ -d "/data/org/.git" ]; then
      echo "git-sync-multi: Single-repo mode (legacy)"
      start_sync "/data/org"
    else
      echo "git-sync-multi: No repositories configured or found"
      while true; do
        ${pkgs.coreutils}/bin/sleep 3600
      done
    fi

    echo "git-sync-multi: Monitoring ''${#PIDS} sync processes"
    wait
  '';

  # Health checker script that monitors emacs and restarts if unhealthy
  # Uses unix socket at /tmp/supervisor.sock (defined in supervisord config)
  # Tracks emacs restart times via timestamp file to reset grace period on each restart
  healthCheckerScript = pkgs.writeShellScriptBin "health-checker" ''
    set -e

    # Health check parameters
    INTERVAL="''${HEALTH_CHECK_INTERVAL:-10}"
    TIMEOUT="''${HEALTH_CHECK_TIMEOUT:-5}"
    # Grace period after emacs restart (seconds)
    GRACE_PERIOD=30
    # Timestamp file for tracking last restart
    TIMESTAMP_FILE="/tmp/emacs-restart-timestamp"

    echo "Health checker starting with interval=$INTERVAL timeout=$TIMEOUT"

    # Initialize timestamp file if it doesn't exist
    if [ ! -f "$TIMESTAMP_FILE" ]; then
      ${pkgs.coreutils}/bin/date +%s > "$TIMESTAMP_FILE"
    fi

    while true; do
      # Check if emacs process exists
      if ! ${pkgs.python3Packages.supervisor}/bin/supervisorctl -s unix:///tmp/supervisor.sock status emacs > /dev/null 2>&1; then
        echo "Emacs not running, skipping health check"
        ${pkgs.coreutils}/bin/sleep $INTERVAL
        continue
      fi

      # Check grace period - only check health after grace period following restart
      LAST_RESTART=$(${pkgs.coreutils}/bin/cat "$TIMESTAMP_FILE" 2>/dev/null || ${pkgs.coreutils}/bin/echo 0)
      CURRENT_TIME=$(${pkgs.coreutils}/bin/date +%s)
      TIME_SINCE_RESTART=$((CURRENT_TIME - LAST_RESTART))

      if [ $TIME_SINCE_RESTART -lt $GRACE_PERIOD ]; then
        # Still within grace period
        ${pkgs.coreutils}/bin/sleep $INTERVAL
        continue
      fi

      # Check health - require 3 consecutive failures with delays before restarting
      if ! ${pkgs.curl}/bin/curl -sf --max-time $TIMEOUT "http://127.0.0.1:${toString port}/health" > /dev/null 2>&1; then
        echo "Health check failed (1/3), waiting 5s..."
        ${pkgs.coreutils}/bin/sleep 5
        if ! ${pkgs.curl}/bin/curl -sf --max-time $TIMEOUT "http://127.0.0.1:${toString port}/health" > /dev/null 2>&1; then
          echo "Health check failed (2/3), waiting 5s..."
          ${pkgs.coreutils}/bin/sleep 5
          if ! ${pkgs.curl}/bin/curl -sf --max-time $TIMEOUT "http://127.0.0.1:${toString port}/health" > /dev/null 2>&1; then
            echo "Emacs failed health check 3 times, restarting..."
            # Record restart time BEFORE restarting so grace period starts immediately
            ${pkgs.coreutils}/bin/date +%s > "$TIMESTAMP_FILE"
            ${pkgs.python3Packages.supervisor}/bin/supervisorctl -s unix:///tmp/supervisor.sock restart emacs || true
          fi
        fi
      fi

      ${pkgs.coreutils}/bin/sleep $INTERVAL
    done
  '';

  # Start emacs using runtime env, so the base image doesn't depend on org-agenda-api code.
  emacsStartScript = pkgs.writeShellScriptBin "start-emacs" ''
    set -e

    EMACS_BIN="${emacsWithPackages}/bin/emacs"
    LOAD_PATH="''${ORG_AGENDA_API_LOAD_PATH:-${orgAgendaApiLoadPathDefault}}"
    INIT_FILE="''${ORG_AGENDA_API_INIT:-${containerInitPath}}"
    CONFIG_DIR="''${ORG_AGENDA_API_CONFIG_DIR:-${containerConfigPath}}"
    CONFIG_ENTRY="''${ORG_AGENDA_API_CONFIG_ENTRYPOINT:-org-config.el}"

    if [ -f "$CONFIG_DIR/$CONFIG_ENTRY" ]; then
      exec "$EMACS_BIN" --fg-daemon=org-api \
        --eval "(setq user-emacs-directory \"$CONFIG_DIR/\")" \
        --eval "(add-to-list 'load-path \"$LOAD_PATH\")" \
        --eval "(require 'org-agenda-api)" \
        --load "$CONFIG_DIR/$CONFIG_ENTRY" \
        --load "$INIT_FILE"
    else
      exec "$EMACS_BIN" --fg-daemon=org-api \
        --eval "(add-to-list 'load-path \"$LOAD_PATH\")" \
        --eval "(require 'org-agenda-api)" \
        --load "$INIT_FILE"
    fi
  '';

  containerSupervisordConf = pkgs.writeText "supervisord.conf" ''
    [supervisord]
    nodaemon=true
    logfile=/dev/stdout
    logfile_maxbytes=0
    pidfile=/tmp/supervisord.pid
    user=root

    [unix_http_server]
    file=/tmp/supervisor.sock

    [supervisorctl]
    serverurl=unix:///tmp/supervisor.sock

    [rpcinterface:supervisor]
    supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

    [program:git-sync]
    command=${gitSyncMultiScript}/bin/git-sync-multi
    autostart=true
    autorestart=true
    startretries=3
    startsecs=5
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0
    environment=PATH="${pkgs.git}/bin:${pkgs.openssh}/bin",GIT_SYNC_INTERVAL="%(ENV_GIT_SYNC_INTERVAL)s",GIT_SYNC_NEW_FILES="%(ENV_GIT_SYNC_NEW_FILES)s",GIT_SYNC_REMOTE="%(ENV_GIT_SYNC_REMOTE)s"

    [program:emacs]
    command=${emacsStartScript}/bin/start-emacs
    autostart=true
    autorestart=true
    startretries=3
    startsecs=5
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0
    environment=PATH="${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.openssh}/bin"

    [program:nginx]
    command=${nginxWithModules}/bin/nginx -c ${nginxConf}
    autostart=true
    autorestart=true
    startretries=3
    startsecs=2
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0

    [program:health-checker]
    command=${healthCheckerScript}/bin/health-checker
    autostart=true
    autorestart=true
    startretries=3
    startsecs=1
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0
  '';

  containerStartupScript = pkgs.writeShellScriptBin "start-org-agenda-api" ''
    set -e

    # Create necessary directories
    ${pkgs.coreutils}/bin/mkdir -p /tmp/nginx_client_body /tmp/nginx_proxy /tmp/nginx_fastcgi /tmp/nginx_uwsgi /tmp/nginx_scgi
    ${pkgs.coreutils}/bin/mkdir -p /data/org
    ${pkgs.coreutils}/bin/mkdir -p /root/.ssh
    ${pkgs.coreutils}/bin/chmod 700 /root/.ssh

    # Setup SSH for git operations
    # Add GitHub's host keys to known_hosts
    ${pkgs.coreutils}/bin/echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" > /root/.ssh/known_hosts
    ${pkgs.coreutils}/bin/echo "github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=" >> /root/.ssh/known_hosts
    ${pkgs.coreutils}/bin/echo "github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=" >> /root/.ssh/known_hosts
    ${pkgs.coreutils}/bin/chmod 644 /root/.ssh/known_hosts

    # Setup SSH private key from env var or mounted file
    if [ -n "$GIT_SSH_PRIVATE_KEY" ]; then
      ${pkgs.coreutils}/bin/echo "Setting up SSH key from environment variable..."
      ${pkgs.coreutils}/bin/echo "$GIT_SSH_PRIVATE_KEY" > /root/.ssh/id_rsa
      ${pkgs.coreutils}/bin/chmod 600 /root/.ssh/id_rsa
    elif [ -f "/secrets/ssh_key" ]; then
      ${pkgs.coreutils}/bin/echo "Setting up SSH key from /secrets/ssh_key..."
      ${pkgs.coreutils}/bin/cp /secrets/ssh_key /root/.ssh/id_rsa
      ${pkgs.coreutils}/bin/chmod 600 /root/.ssh/id_rsa
    fi

    # Setup nginx authentication
    setup_nginx_auth() {
      if [ -n "$AUTH_HTPASSWD_FILE" ] && [ -f "$AUTH_HTPASSWD_FILE" ]; then
        # Use provided htpasswd file
        ${pkgs.coreutils}/bin/echo "Using htpasswd file: $AUTH_HTPASSWD_FILE"
        ${pkgs.coreutils}/bin/cat > /tmp/nginx-auth.conf << EOF
    auth_basic "org-agenda-api";
    auth_basic_user_file $AUTH_HTPASSWD_FILE;
    EOF
      elif [ -n "$AUTH_USER" ] && [ -n "$AUTH_PASSWORD" ]; then
        # Generate htpasswd from env vars
        ${pkgs.coreutils}/bin/echo "Generating htpasswd for user: $AUTH_USER"
        # Create htpasswd file using openssl
        ${pkgs.openssl}/bin/openssl passwd -apr1 "$AUTH_PASSWORD" > /tmp/htpasswd.tmp
        ${pkgs.coreutils}/bin/echo "$AUTH_USER:$(cat /tmp/htpasswd.tmp)" > /tmp/htpasswd
        rm /tmp/htpasswd.tmp
        ${pkgs.coreutils}/bin/cat > /tmp/nginx-auth.conf << EOF
    auth_basic "org-agenda-api";
    auth_basic_user_file /tmp/htpasswd;
    EOF
      else
        # No auth configured
        ${pkgs.coreutils}/bin/echo "No auth configured"
        ${pkgs.coreutils}/bin/cat > /tmp/nginx-auth.conf << EOF
    auth_basic off;
    EOF
      fi
    }

    # Call auth setup
    setup_nginx_auth

    # Configure git user identity from environment
    if [ -n "$GIT_USER_EMAIL" ]; then
      ${pkgs.git}/bin/git config --global user.email "$GIT_USER_EMAIL"
    fi
    if [ -n "$GIT_USER_NAME" ]; then
      ${pkgs.git}/bin/git config --global user.name "$GIT_USER_NAME"
    fi

    # Handle git repository setup if provided
    if [ -n "$GIT_SYNC_REPOSITORY" ]; then
      ${pkgs.git}/bin/git config --global --add safe.directory /data/org
      if [ ! -d "/data/org/.git" ]; then
        ${pkgs.coreutils}/bin/echo "Cloning repository from $GIT_SYNC_REPOSITORY..."
        ${pkgs.git}/bin/git clone "$GIT_SYNC_REPOSITORY" /data/org
      fi
    else
      ${pkgs.git}/bin/git config --global --add safe.directory /data/org
    fi

    ${pkgs.coreutils}/bin/echo "Starting supervisord..."
    exec ${pkgs.python3Packages.supervisor}/bin/supervisord -c ${containerSupervisordConf}
  '';

  containerInitRoot = pkgs.runCommand "org-agenda-api-container-init" {} ''
    mkdir -p $out/etc/org-agenda-api
    cp ${containerInitEl} $out${containerInitPath}
  '';

  mkContainerBase = {
    name ? "org-agenda-api-base",
    tag ? "latest",
    extraPackages ? [],
  }:
    let
      baseEnv = pkgs.buildEnv {
        name = "org-agenda-api-base-env";
        paths = [
          emacsWithPackages
          nginxWithModules
          pkgs.curl
          pkgs.coreutils
          pkgs.bash
          pkgs.git
          pkgs.openssh
          pkgs.jq
          pkgs.cacert
          pkgs.python3Packages.supervisor
          pkgs.tzdata
          gitSyncRs
          # QoL tools for interactive use
          pkgs.less
          pkgs.ncurses
          pkgs.readline
          # Runtime scripts
          gitSyncMultiScript
          healthCheckerScript
          emacsStartScript
          containerStartupScript
        ] ++ extraPackages;
        pathsToLink = [ "/bin" ];
      };
    in
    pkgs.dockerTools.buildLayeredImage {
      inherit name tag;

      contents = [ baseEnv ];

      fakeRootCommands = ''
        ${pkgs.dockerTools.shadowSetup}
        groupadd --system nginx
        useradd --system --gid nginx nginx
        mkdir -p /data/org
        mkdir -p /tmp
        mkdir -p /root/.ssh
        mkdir -p /secrets
        mkdir -p /var/log/nginx
        mkdir -p /var/cache/nginx
        mkdir -p /var/www/mova
        chmod 1777 /tmp
        chmod 700 /root/.ssh
        chown nginx:nginx /var/log/nginx /var/cache/nginx
        # Copy mova web app
        cp -r ${movaWeb}/* /var/www/mova/
      '';
      enableFakechroot = true;

      # Maximum number of layers (default 100)
      maxLayers = 100;
    };

  mkContainer = {
    name ? "org-agenda-api",
    tag ? "latest",
    baseImage ? null,
    customElispFile ? null,
    # Directory containing emacs config with straight/ subdirectory
    # Should include: README.el, org-config.el, org-config-*.el, straight/
    emacsConfigDir ? null,
    # Entry point elisp file within emacsConfigDir (relative path)
    # This file should load org-agenda-api and start the server
    emacsConfigEntryPoint ? "org-config.el",
    extraPackages ? [],
  }:
    let
      emacsConfigPackage = if emacsConfigDir != null then
        pkgs.runCommand "emacs-config" {} ''
          mkdir -p $out
          # Copy elisp files
          for f in ${emacsConfigDir}/*.el; do
            if [ -f "$f" ]; then
              cp "$f" $out/
            fi
          done
          # Copy straight directory (repos and build)
          if [ -d "${emacsConfigDir}/straight" ]; then
            cp -r ${emacsConfigDir}/straight $out/
          fi
        ''
      else null;

      emacsConfigRoot = if emacsConfigPackage != null then
        pkgs.runCommand "emacs-config-root" {} ''
          mkdir -p $out${containerConfigPath}
          cp -r ${emacsConfigPackage}/* $out${containerConfigPath}/
        ''
      else null;

      baseImageResolved = if baseImage != null then
        baseImage
      else
        mkContainerBase {
          name = "${name}-base";
          tag = tag;
          extraPackages = extraPackages;
        };

      overlayExtras = if baseImage != null then extraPackages else [];

      copyToRoot =
        [ orgAgendaApiSitelisp containerInitRoot ]
        ++ lib.optional (emacsConfigRoot != null) emacsConfigRoot
        ++ overlayExtras;

      env = [
        # Timezone data for TZ environment variable support
        "TZDIR=${pkgs.tzdata}/share/zoneinfo"
        # Global PATH for interactive shells (SSH, exec)
        "PATH=/bin"
        # Editor preference
        "EDITOR=emacs"
        # Terminal type for readline/ncurses
        "TERM=xterm-256color"
        # SSL certificates for HTTPS git repos
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        # Org agenda API settings
        "ORG_AGENDA_FILES=/data/org"
        "ORG_INBOX_FILE=/data/org/inbox.org"
        "ORG_API_PORT=${toString port}"
        "ORG_AGENDA_API_GIT_COMMIT=${gitCommit}"
        "ORG_AGENDA_API_VERSION=${orgAgendaApiVersion}"
        # Worker lifecycle - restart emacs periodically for freshness
        # Emacs exits after completing a request when lifetime is reached
        # Set to empty to disable, or override with your own value
        "ORG_API_MAX_LIFETIME=900"
        # Health checker settings - monitors emacs and restarts if unhealthy
        # Checks every INTERVAL seconds; if check fails, retries immediately once
        "HEALTH_CHECK_INTERVAL=10"
        "HEALTH_CHECK_TIMEOUT=5"
        # Git sync settings
        "GIT_SYNC_INTERVAL=60"
        "GIT_SYNC_NEW_FILES=true"
        "GIT_SYNC_REMOTE=origin"
        # Git user (for commits)
        "GIT_USER_EMAIL=org-agenda-api@localhost"
        "GIT_USER_NAME=org-agenda-api"
        # Emacs runtime configuration
        "ORG_AGENDA_API_LOAD_PATH=${orgAgendaApiLoadPathDefault}"
        "ORG_AGENDA_API_INIT=${containerInitPath}"
        "ORG_AGENDA_API_CONFIG_DIR=${containerConfigPath}"
        "ORG_AGENDA_API_CONFIG_ENTRYPOINT=${emacsConfigEntryPoint}"
        # Git repository options (choose one):
        # GIT_SYNC_REPOSITORIES - JSON array for multiple repos:
        #   [{"url": "git@github.com:user/org.git", "path": "org"},
        #    {"url": "git@github.com:user/work.git", "path": "work"}]
        #   Repos are cloned to /data/<path>/
        # GIT_SYNC_REPOSITORY - single repo URL (legacy), clones to /data/org
        # GIT_SSH_PRIVATE_KEY - or mount key to /secrets/ssh_key
        # ORG_API_CUSTOM_ELISP - path to custom elisp file
      ] ++ lib.optional (customElispFile != null) "ORG_API_CUSTOM_ELISP=${customElispFile}";
    in
    pkgs.dockerTools.buildImage {
      inherit name tag;
      fromImage = baseImageResolved;

      copyToRoot = copyToRoot;

      config = {
        Cmd = [ "${containerStartupScript}/bin/start-org-agenda-api" ];
        ExposedPorts = {
          "80/tcp" = {};
        };
        Volumes = {
          "/data" = {};
          "/secrets" = {};
        };
        Env = env;
      };
    };

in
{
  inherit mkContainerBase mkContainer;
}
