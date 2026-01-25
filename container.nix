{ pkgs, emacsWithPackages, gitSyncRs, orgAgendaApiSitelisp, containerInitEl, gitCommit ? "unknown", movaWeb }:

{
  name ? "org-agenda-api",
  tag ? "latest",
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
  port = 2025;

  # Nginx with headers-more module for clearing WWW-Authenticate header
  nginxWithModules = pkgs.nginx.override {
    modules = [ pkgs.nginxModules.moreheaders ];
  };

  # Package the emacs config directory if provided
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

  # Path where config will be in the container
  containerConfigPath = "/emacs-config";

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
          proxy_pass http://emacs;
          proxy_http_version 1.1;

          # CORS headers
          add_header 'Access-Control-Allow-Origin' '*' always;
          add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS' always;
          add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization' always;

          # Handle preflight
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization';
            add_header 'Access-Control-Max-Age' 86400;
            add_header 'Content-Length' 0;
            add_header 'Content-Type' 'text/plain';
            return 204;
          }
        }

        # API endpoints - proxy to emacs with auth
        # Support both /endpoint and /api/endpoint paths for backwards compatibility
        location ~ ^/(api/)?(agenda|agenda-files|get-all-todos|get-todays-agenda|complete|update|delete|todo-states|capture-templates|capture|custom-views|custom-view|debug-config|filter-options|metadata|restart|category-types|categories|category-tasks|category-capture|habit-config|habit-status)$ {
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

          # CORS headers
          add_header 'Access-Control-Allow-Origin' '*' always;
          add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, PATCH, OPTIONS' always;
          add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization' always;

          # Handle preflight
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, PATCH, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization';
            add_header 'Access-Control-Max-Age' 86400;
            add_header 'Content-Length' 0;
            add_header 'Content-Type' 'text/plain';
            return 204;
          }
        }

        # Static files - serve mova web app (no auth)
        location / {
          try_files $uri $uri/ /index.html;
        }
      }
    }
  '';

  # Custom elisp environment variable (baked into image if provided)
  customElispEnv = if customElispFile != null
    then "ORG_API_CUSTOM_ELISP=${customElispFile}"
    else "";

  # Multi-repo git sync wrapper script
  gitSyncMultiScript = pkgs.writeShellScript "git-sync-multi" ''
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
      ${gitSyncRs}/bin/git-sync-rs watch -d "$repo_path" &
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
  healthCheckerScript = pkgs.writeShellScript "health-checker" ''
    INTERVAL=''${HEALTH_CHECK_INTERVAL:-10}
    TIMEOUT=''${HEALTH_CHECK_TIMEOUT:-5}

    echo "Health checker starting (interval=''${INTERVAL}s, timeout=''${TIMEOUT}s)"

    # Wait for emacs to start up
    ${pkgs.coreutils}/bin/sleep 15

    while true; do
      # First check
      if ! ${pkgs.curl}/bin/curl -sf --max-time $TIMEOUT "http://127.0.0.1:${toString port}/health" > /dev/null 2>&1; then
        # Immediate retry
        if ! ${pkgs.curl}/bin/curl -sf --max-time $TIMEOUT "http://127.0.0.1:${toString port}/health" > /dev/null 2>&1; then
          echo "Emacs failed health check twice, restarting..."
          ${pkgs.python3Packages.supervisor}/bin/supervisorctl restart emacs || true
        fi
      fi

      ${pkgs.coreutils}/bin/sleep $INTERVAL
    done
  '';

  # Path to org-agenda-api site-lisp directory
  orgAgendaApiLoadPath = "${orgAgendaApiSitelisp}/share/emacs/site-lisp";

  # Emacs command varies based on whether we have a custom config dir
  # Note: Using single quotes around --eval args so double quotes are literal
  emacsCommand = if emacsConfigDir != null then
    # With custom config: set user-emacs-directory and load the entry point
    "${emacsWithPackages}/bin/emacs --fg-daemon=org-api --eval '(setq user-emacs-directory \"${containerConfigPath}/\")' --eval '(add-to-list (quote load-path) \"${orgAgendaApiLoadPath}\")' --eval '(require (quote org-agenda-api))' --load ${containerConfigPath}/${emacsConfigEntryPoint} --load ${containerInitEl}"
  else
    # Without custom config: just load org-agenda-api and container-init
    "${emacsWithPackages}/bin/emacs --fg-daemon=org-api --eval '(add-to-list (quote load-path) \"${orgAgendaApiLoadPath}\")' --eval '(require (quote org-agenda-api))' --load ${containerInitEl}";

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
    command=${gitSyncMultiScript}
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
    command=${emacsCommand}
    autostart=true
    autorestart=true
    startretries=3
    startsecs=5
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0
    environment=PATH="${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.openssh}/bin"${if customElispFile != null then ",${customElispEnv}" else ""}

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
    command=${healthCheckerScript}
    autostart=true
    autorestart=true
    startretries=3
    startsecs=1
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0
  '';

  containerStartupScript = pkgs.writeShellScript "start-org-agenda-api" ''
    set -e

    # Create necessary directories
    ${pkgs.coreutils}/bin/mkdir -p /tmp/nginx_client_body /tmp/nginx_proxy /tmp/nginx_fastcgi /tmp/nginx_uwsgi /tmp/nginx_scgi
    ${pkgs.coreutils}/bin/mkdir -p /data/org
    ${pkgs.coreutils}/bin/mkdir -p /root/.ssh

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
        ${pkgs.apacheHttpd}/bin/htpasswd -cb /tmp/.htpasswd "$AUTH_USER" "$AUTH_PASSWORD"
        ${pkgs.coreutils}/bin/chmod 644 /tmp/.htpasswd
        ${pkgs.coreutils}/bin/cat > /tmp/nginx-auth.conf << EOF
    auth_basic "org-agenda-api";
    auth_basic_user_file /tmp/.htpasswd;
    EOF
      else
        # No auth configured
        ${pkgs.coreutils}/bin/echo "Warning: No authentication configured. API is open."
        ${pkgs.coreutils}/bin/echo "# No auth configured" > /tmp/nginx-auth.conf
      fi
    }

    setup_nginx_auth

    # Setup SSH configuration
    setup_ssh_key() {
      local key_path="$1"
      ${pkgs.coreutils}/bin/cat > /root/.ssh/config << EOF
    Host *
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      IdentityFile $key_path
    EOF
      ${pkgs.coreutils}/bin/chmod 600 /root/.ssh/config
    }

    # If SSH key content is provided via env var, write it to a file
    if [ -n "$GIT_SSH_PRIVATE_KEY" ]; then
      ${pkgs.coreutils}/bin/echo "$GIT_SSH_PRIVATE_KEY" > /root/.ssh/key
      ${pkgs.coreutils}/bin/chmod 600 /root/.ssh/key
      setup_ssh_key /root/.ssh/key
    # If SSH key file is mounted at /secrets/ssh_key
    elif [ -f "/secrets/ssh_key" ]; then
      ${pkgs.coreutils}/bin/chmod 600 /secrets/ssh_key 2>/dev/null || true
      setup_ssh_key /secrets/ssh_key
    fi

    # Set git config for commits
    ${pkgs.git}/bin/git config --global user.email "''${GIT_USER_EMAIL:-org-agenda-api@localhost}"
    ${pkgs.git}/bin/git config --global user.name "''${GIT_USER_NAME:-org-agenda-api}"

    # Clone and configure repositories
    if [ -n "$GIT_SYNC_REPOSITORIES" ]; then
      ${pkgs.coreutils}/bin/echo "Configuring multiple repositories..."
      ${pkgs.jq}/bin/jq -c '.[]' <<< "$GIT_SYNC_REPOSITORIES" 2>/dev/null | while read -r repo; do
        url=$(${pkgs.jq}/bin/jq -r '.url' <<< "$repo")
        path=$(${pkgs.jq}/bin/jq -r '.path' <<< "$repo")
        repo_dir="/data/$path"
        ${pkgs.coreutils}/bin/mkdir -p "$repo_dir"
        ${pkgs.git}/bin/git config --global --add safe.directory "$repo_dir"
        if [ ! -d "$repo_dir/.git" ]; then
          ${pkgs.coreutils}/bin/echo "Cloning $url to $repo_dir..."
          ${pkgs.git}/bin/git clone "$url" "$repo_dir"
        else
          ${pkgs.coreutils}/bin/echo "Repository already exists at $repo_dir"
        fi
      done
    elif [ -n "$GIT_SYNC_REPOSITORY" ]; then
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

in
pkgs.dockerTools.buildImage {
  inherit name tag;

  copyToRoot = pkgs.buildEnv {
    name = "org-agenda-api-root";
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
      gitSyncRs
      # QoL tools for interactive use
      pkgs.less
      pkgs.ncurses
      pkgs.readline
    ] ++ extraPackages;
    pathsToLink = [ "/bin" "/lib" "/share" "/etc" ];
  };

  runAsRoot = ''
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
    ${if emacsConfigPackage != null then ''
      # Copy emacs config into container
      mkdir -p ${containerConfigPath}
      cp -r ${emacsConfigPackage}/* ${containerConfigPath}/
    '' else ""}
  '';

  config = {
    Cmd = [ "${containerStartupScript}" ];
    ExposedPorts = {
      "80/tcp" = {};
    };
    Volumes = {
      "/data" = {};
      "/secrets" = {};
    };
    Env = [
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
      # Git repository options (choose one):
      # GIT_SYNC_REPOSITORIES - JSON array for multiple repos:
      #   [{"url": "git@github.com:user/org.git", "path": "org"},
      #    {"url": "git@github.com:user/work.git", "path": "work"}]
      #   Repos are cloned to /data/<path>/
      # GIT_SYNC_REPOSITORY - single repo URL (legacy), clones to /data/org
      # GIT_SSH_PRIVATE_KEY - or mount key to /secrets/ssh_key
      # ORG_API_CUSTOM_ELISP - path to custom elisp file
    ];
  };
}
