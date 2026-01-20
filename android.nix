{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.org-agenda-api;

  # Emacs with required packages
  emacsWithPackages = pkgs.emacs-nox.pkgs.withPackages (epkgs: [
    epkgs.simple-httpd
    epkgs.org
  ] ++ cfg.extraEmacsPackages);

  # Nginx with headers-more module
  nginxWithModules = pkgs.nginx.override {
    modules = [ pkgs.nginxModules.moreheaders ];
  };

  # The elisp files from this repo
  orgAgendaApiEl = ./org-agenda-api.el;
  containerInitEl = ./container-init.el;

  # Config directory
  configDir = "${config.xdg.configHome}/org-agenda-api";

  # Nginx config
  nginxConf = pkgs.writeText "nginx.conf" ''
    daemon off;
    error_log stderr info;
    pid ${configDir}/nginx.pid;
    events {
      worker_connections 64;
    }
    http {
      include ${nginxWithModules}/conf/mime.types;
      default_type application/octet-stream;
      access_log /dev/stdout;
      client_body_temp_path ${configDir}/tmp/nginx_client_body;
      proxy_temp_path ${configDir}/tmp/nginx_proxy;
      fastcgi_temp_path ${configDir}/tmp/nginx_fastcgi;
      uwsgi_temp_path ${configDir}/tmp/nginx_uwsgi;
      scgi_temp_path ${configDir}/tmp/nginx_scgi;

      upstream emacs {
        server 127.0.0.1:${toString cfg.internalPort};
      }

      server {
        listen ${toString cfg.port};

        # Health check endpoint - no auth required
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
          add_header 'Access-Control-Allow-Origin' '*' always;
        }

        # API endpoints - proxy to emacs with auth
        location ~ ^/(api/)?(agenda|agenda-files|get-all-todos|get-todays-agenda|complete|update|delete|todo-states|capture-templates|capture|custom-views|custom-view|debug-config|filter-options|metadata|restart|category-types|categories|category-tasks|category-capture|habit-config|habit-status)$ {
          ${if cfg.nginx.auth.enable then ''
          auth_basic "org-agenda-api";
          auth_basic_user_file ${configDir}/auth/.htpasswd;
          '' else ""}

          # Clear WWW-Authenticate header to prevent browser's native auth popup
          more_clear_headers 'WWW-Authenticate';

          # Strip /api prefix if present
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

        # Default - return 404 for unknown paths
        location / {
          return 404;
        }
      }
    }
  '';

  # Emacs port (internal if nginx, external if direct)
  emacsPort = if cfg.nginx.enable then cfg.internalPort else cfg.port;

  # Emacs command
  emacsCommand = "${emacsWithPackages}/bin/emacs --fg-daemon=org-api --load ${orgAgendaApiEl} --load ${containerInitEl}";

  # Git sync script (multi-repo support)
  gitSyncScript = pkgs.writeShellScript "git-sync-multi" ''
    PIDS=""

    cleanup() {
      echo "git-sync: Stopping all sync processes..."
      for pid in $PIDS; do
        kill $pid 2>/dev/null || true
      done
      wait
      exit 0
    }

    trap cleanup SIGTERM SIGINT

    start_sync() {
      local repo_path="$1"
      echo "git-sync: Starting sync for $repo_path"
      ${cfg.gitSync.package}/bin/git-sync-rs watch -d "$repo_path" &
      PIDS="$PIDS $!"
    }

    ${concatMapStringsSep "\n" (repo: ''
      if [ -d "${cfg.orgDirectory}/${repo.path}/.git" ]; then
        start_sync "${cfg.orgDirectory}/${repo.path}"
      else
        echo "git-sync: WARNING - ${cfg.orgDirectory}/${repo.path} is not a git repository"
      fi
    '') cfg.gitSync.repositories}

    if [ -z "$PIDS" ]; then
      echo "git-sync: No repositories to sync, sleeping..."
      while true; do sleep 3600; done
    fi

    echo "git-sync: Monitoring sync processes"
    wait
  '';

  # Health checker script
  healthCheckerScript = pkgs.writeShellScript "health-checker" ''
    INTERVAL=${toString cfg.healthCheck.interval}
    TIMEOUT=${toString cfg.healthCheck.timeout}

    echo "Health checker starting (interval=''${INTERVAL}s, timeout=''${TIMEOUT}s)"

    # Wait for emacs to start
    sleep 15

    while true; do
      if ! ${pkgs.curl}/bin/curl -sf --max-time $TIMEOUT "http://127.0.0.1:${toString emacsPort}/health" > /dev/null 2>&1; then
        # Immediate retry
        if ! ${pkgs.curl}/bin/curl -sf --max-time $TIMEOUT "http://127.0.0.1:${toString emacsPort}/health" > /dev/null 2>&1; then
          echo "Emacs failed health check twice, restarting..."
          ${pkgs.python3Packages.supervisor}/bin/supervisorctl -c ${configDir}/supervisord.conf restart emacs || true
        fi
      fi
      sleep $INTERVAL
    done
  '';

  # Supervisord config
  supervisordConf = pkgs.writeText "supervisord.conf" ''
    [supervisord]
    nodaemon=true
    logfile=/dev/stdout
    logfile_maxbytes=0
    pidfile=${configDir}/supervisord.pid

    [unix_http_server]
    file=${configDir}/supervisor.sock

    [supervisorctl]
    serverurl=unix://${configDir}/supervisor.sock

    [rpcinterface:supervisor]
    supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

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
    environment=PATH="${pkgs.coreutils}/bin:${pkgs.git}/bin",ORG_AGENDA_FILES="${cfg.orgDirectory}",ORG_INBOX_FILE="${if cfg.inboxFile != null then cfg.inboxFile else "${cfg.orgDirectory}/inbox.org"}",ORG_API_PORT="${toString emacsPort}",ORG_API_MAX_LIFETIME="${toString cfg.maxLifetime}"${optionalString (cfg.customElispFile != null) ",ORG_API_CUSTOM_ELISP=\"${cfg.customElispFile}\""}${optionalString (cfg.customElispContent != "") ",ORG_API_CUSTOM_ELISP_CONTENT=\"${cfg.customElispContent}\""}

    ${optionalString cfg.nginx.enable ''
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
    ''}

    ${optionalString (cfg.gitSync.enable && cfg.gitSync.repositories != []) ''
    [program:git-sync]
    command=${gitSyncScript}
    autostart=true
    autorestart=true
    startretries=3
    startsecs=5
    stdout_logfile=/dev/stdout
    stdout_logfile_maxbytes=0
    stderr_logfile=/dev/stderr
    stderr_logfile_maxbytes=0
    environment=PATH="${pkgs.git}/bin:${pkgs.openssh}/bin",GIT_SYNC_INTERVAL="${toString cfg.gitSync.interval}"${optionalString (cfg.gitSync.sshKeyFile != null) ",GIT_SSH_COMMAND=\"ssh -i ${cfg.gitSync.sshKeyFile} -o StrictHostKeyChecking=no\""}
    ''}

    ${optionalString cfg.healthCheck.enable ''
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
    ''}
  '';

  # Start script
  startScript = pkgs.writeShellScriptBin "org-agenda-api-start" ''
    set -e

    DAEMON=false
    if [ "$1" = "-d" ] || [ "$1" = "--daemon" ]; then
      DAEMON=true
    fi

    # Create directories
    mkdir -p ${configDir}/tmp/nginx_client_body
    mkdir -p ${configDir}/tmp/nginx_proxy
    mkdir -p ${configDir}/tmp/nginx_fastcgi
    mkdir -p ${configDir}/tmp/nginx_uwsgi
    mkdir -p ${configDir}/tmp/nginx_scgi
    mkdir -p ${configDir}/auth
    mkdir -p ${cfg.orgDirectory}

    # Setup auth if enabled
    ${optionalString cfg.nginx.auth.enable ''
    ${if cfg.nginx.auth.passwordFile != null then ''
    PASSWORD=$(cat ${cfg.nginx.auth.passwordFile})
    '' else ''
    PASSWORD="${cfg.nginx.auth.password}"
    ''}
    ${pkgs.apacheHttpd}/bin/htpasswd -cb ${configDir}/auth/.htpasswd "${cfg.nginx.auth.user}" "$PASSWORD"
    chmod 600 ${configDir}/auth/.htpasswd
    ''}

    # Copy supervisord config
    cp ${supervisordConf} ${configDir}/supervisord.conf

    echo "Starting org-agenda-api on port ${toString cfg.port}..."

    if [ "$DAEMON" = true ]; then
      ${pkgs.python3Packages.supervisor}/bin/supervisord -c ${configDir}/supervisord.conf &
      echo $! > ${configDir}/daemon.pid
      echo "Started in background (PID: $(cat ${configDir}/daemon.pid))"
    else
      exec ${pkgs.python3Packages.supervisor}/bin/supervisord -c ${configDir}/supervisord.conf
    fi
  '';

  # Stop script
  stopScript = pkgs.writeShellScriptBin "org-agenda-api-stop" ''
    if [ -f ${configDir}/daemon.pid ]; then
      PID=$(cat ${configDir}/daemon.pid)
      if kill -0 $PID 2>/dev/null; then
        echo "Stopping org-agenda-api (PID: $PID)..."
        kill $PID
        rm -f ${configDir}/daemon.pid
        echo "Stopped."
      else
        echo "Process not running."
        rm -f ${configDir}/daemon.pid
      fi
    else
      echo "No PID file found. Trying supervisorctl..."
      ${pkgs.python3Packages.supervisor}/bin/supervisorctl -c ${configDir}/supervisord.conf shutdown || true
    fi
  '';

  # Status script
  statusScript = pkgs.writeShellScriptBin "org-agenda-api-status" ''
    if [ -f ${configDir}/daemon.pid ]; then
      PID=$(cat ${configDir}/daemon.pid)
      if kill -0 $PID 2>/dev/null; then
        echo "org-agenda-api is running (PID: $PID)"
        ${pkgs.python3Packages.supervisor}/bin/supervisorctl -c ${configDir}/supervisord.conf status
        exit 0
      fi
    fi

    # Try to connect to supervisor socket
    if [ -S ${configDir}/supervisor.sock ]; then
      ${pkgs.python3Packages.supervisor}/bin/supervisorctl -c ${configDir}/supervisord.conf status
    else
      echo "org-agenda-api is not running"
      exit 1
    fi
  '';

  # Restart script (just restarts emacs, not nginx/git-sync)
  restartScript = pkgs.writeShellScriptBin "org-agenda-api-restart" ''
    echo "Restarting emacs..."
    ${pkgs.python3Packages.supervisor}/bin/supervisorctl -c ${configDir}/supervisord.conf restart emacs
  '';

in {
  options.services.org-agenda-api = {
    enable = mkEnableOption "org-agenda-api server for Android";

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "External port for the API (nginx or direct emacs).";
    };

    internalPort = mkOption {
      type = types.port;
      default = 2025;
      description = "Internal port for emacs when nginx is enabled.";
    };

    orgDirectory = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/org";
      description = "Directory containing org files.";
    };

    inboxFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to inbox.org file. Defaults to orgDirectory/inbox.org.";
    };

    agendaFiles = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = "List of org files/directories. Auto-discovers if not set.";
    };

    customElispFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to custom elisp file to load.";
    };

    customElispContent = mkOption {
      type = types.str;
      default = "";
      description = "Inline elisp content to evaluate.";
    };

    maxLifetime = mkOption {
      type = types.int;
      default = 900;
      description = "Restart emacs after this many seconds (0 to disable).";
    };

    extraEmacsPackages = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Additional emacs packages to include.";
    };

    nginx = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable nginx reverse proxy for auth and CORS.";
      };

      auth = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable HTTP basic authentication.";
        };

        user = mkOption {
          type = types.str;
          default = "api";
          description = "Username for HTTP basic auth.";
        };

        password = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Password for HTTP basic auth (use passwordFile instead for security).";
        };

        passwordFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Path to file containing password.";
        };
      };
    };

    gitSync = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable git-sync for org repositories.";
      };

      package = mkOption {
        type = types.package;
        default = pkgs.git-sync-rs or (throw "git-sync-rs not available, please provide via gitSync.package");
        description = "git-sync-rs package to use.";
      };

      repositories = mkOption {
        type = types.listOf (types.submodule {
          options = {
            url = mkOption {
              type = types.str;
              description = "Git repository URL.";
            };
            path = mkOption {
              type = types.str;
              description = "Local path relative to orgDirectory.";
            };
          };
        });
        default = [];
        description = "Repositories to sync.";
      };

      interval = mkOption {
        type = types.int;
        default = 60;
        description = "Sync interval in seconds.";
      };

      sshKeyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Path to SSH private key for git operations.";
      };
    };

    healthCheck = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable health checking and auto-restart.";
      };

      interval = mkOption {
        type = types.int;
        default = 10;
        description = "Health check interval in seconds.";
      };

      timeout = mkOption {
        type = types.int;
        default = 5;
        description = "Health check timeout in seconds.";
      };
    };
  };

  config = mkIf cfg.enable {
    home.packages = [
      emacsWithPackages
      startScript
      stopScript
      statusScript
      restartScript
      pkgs.python3Packages.supervisor
      pkgs.curl
    ] ++ optional cfg.nginx.enable nginxWithModules
      ++ optional cfg.nginx.auth.enable pkgs.apacheHttpd
      ++ optional cfg.gitSync.enable cfg.gitSync.package;

    # Ensure XDG config directory exists
    xdg.configFile."org-agenda-api/.keep".text = "";
  };
}
