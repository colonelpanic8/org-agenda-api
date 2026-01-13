{ pkgs, emacsWithPackages, gitSyncRs, orgAgendaApiEl, containerInitEl }:

{
  name ? "org-agenda-api",
  tag ? "latest",
  customElispFile ? null,
  extraPackages ? [],
}:

let
  port = 2025;

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

        # Health check endpoint - no auth required for monitoring tools
        location /health {
          proxy_pass http://emacs;
          proxy_http_version 1.1;
          proxy_connect_timeout 5s;
          proxy_read_timeout 5s;
        }

        location / {
          # Include auth config (generated at startup)
          include /tmp/nginx-auth.conf;

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
      }
    }
  '';

  # Custom elisp environment variable (baked into image if provided)
  customElispEnv = if customElispFile != null
    then "ORG_API_CUSTOM_ELISP=${customElispFile}"
    else "";

  # Health checker script that monitors emacs and restarts if unhealthy
  healthCheckerScript = pkgs.writeShellScript "health-checker" ''
    INTERVAL=''${HEALTH_CHECK_INTERVAL:-10}
    TIMEOUT=''${HEALTH_CHECK_TIMEOUT:-5}

    echo "Health checker starting (interval=''${INTERVAL}s, timeout=''${TIMEOUT}s)"

    # Wait for emacs to start up
    sleep 15

    while true; do
      # First check
      if ! ${pkgs.curl}/bin/curl -sf --max-time $TIMEOUT "http://127.0.0.1:${toString port}/health" > /dev/null 2>&1; then
        # Immediate retry
        if ! ${pkgs.curl}/bin/curl -sf --max-time $TIMEOUT "http://127.0.0.1:${toString port}/health" > /dev/null 2>&1; then
          echo "Emacs failed health check twice, restarting..."
          ${pkgs.python3Packages.supervisor}/bin/supervisorctl restart emacs || true
        fi
      fi

      sleep $INTERVAL
    done
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
    command=${gitSyncRs}/bin/git-sync-rs watch -d /data/org
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
    command=${emacsWithPackages}/bin/emacs --fg-daemon=org-api --load ${orgAgendaApiEl} --load ${containerInitEl}
    autostart=true
    autorestart=true
    startretries=3
    startsecs=5
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0
    environment=PATH="${pkgs.git}/bin:${pkgs.openssh}/bin"${if customElispFile != null then ",${customElispEnv}" else ""}

    [program:nginx]
    command=${pkgs.nginx}/bin/nginx -c ${nginxConf}
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
    # Mark /data/org as safe directory (needed when mounting from different user)
    ${pkgs.git}/bin/git config --global --add safe.directory /data/org

    # If GIT_SYNC_REPOSITORY is set and /data/org is empty, clone the repo
    if [ -n "$GIT_SYNC_REPOSITORY" ] && [ ! -d "/data/org/.git" ]; then
      ${pkgs.coreutils}/bin/echo "Cloning repository from $GIT_SYNC_REPOSITORY..."
      ${pkgs.git}/bin/git clone "$GIT_SYNC_REPOSITORY" /data/org
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
      pkgs.nginx
      pkgs.curl
      pkgs.coreutils
      pkgs.bash
      pkgs.git
      pkgs.openssh
      pkgs.python3Packages.supervisor
      gitSyncRs
    ] ++ extraPackages;
    pathsToLink = [ "/bin" "/lib" "/share" ];
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
    chmod 1777 /tmp
    chmod 700 /root/.ssh
    chown nginx:nginx /var/log/nginx /var/cache/nginx
  '';

  config = {
    Cmd = [ "${containerStartupScript}" ];
    ExposedPorts = {
      "80/tcp" = {};
    };
    Volumes = {
      "/data/org" = {};
      "/secrets" = {};
    };
    Env = [
      # Org agenda API settings
      "ORG_AGENDA_FILES=/data/org"
      "ORG_INBOX_FILE=/data/org/inbox.org"
      "ORG_API_PORT=${toString port}"
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
      # GIT_SYNC_REPOSITORY - set this to clone on startup
      # GIT_SSH_PRIVATE_KEY - or mount key to /secrets/ssh_key
      # ORG_API_CUSTOM_ELISP - path to custom elisp file
    ];
  };
}
