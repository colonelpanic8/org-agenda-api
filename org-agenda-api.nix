{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.myModules.org-agenda-api;
in
{
  options = {
    myModules.org-agenda-api = {
      enable = mkEnableOption "org-agenda-api emacs HTTP server";

      port = mkOption {
        type = types.int;
        default = 2025;
        description = "Port for the emacs HTTP server to listen on.";
      };

      user = mkOption {
        type = types.str;
        default = "root";
        description = "User to run the emacs daemon as.";
      };

      elispFile = mkOption {
        type = types.path;
        description = "Path to the elisp file that starts the org-agenda-api server.";
      };

      daemonName = mkOption {
        type = types.str;
        default = "org-api";
        description = "Name for the emacs daemon instance.";
      };

      emacsPackage = mkOption {
        type = types.package;
        default = pkgs.emacs;
        description = "Emacs package to use.";
      };

      nginx = {
        enable = mkEnableOption "nginx reverse proxy for org-agenda-api";

        domain = mkOption {
          type = types.str;
          description = "Domain name for the nginx virtual host.";
        };

        enableACME = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to enable ACME for SSL certificates.";
        };

        forceSSL = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to force SSL.";
        };

        basicAuthFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to htpasswd file for basic auth. If null, no auth is required.";
        };

        corsAllowOrigin = mkOption {
          type = types.str;
          default = "*";
          description = "Value for Access-Control-Allow-Origin header.";
        };

        corsAllowMethods = mkOption {
          type = types.str;
          default = "POST, PUT, DELETE, GET, PATCH, OPTIONS";
          description = "Value for Access-Control-Allow-Methods header.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.services.emacs-org-api = {
      description = "Emacs org-agenda-api server";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = ''${pkgs.runtimeShell} -l -c "${getExe' cfg.emacsPackage "emacs"} --load ${cfg.elispFile} --daemon=${cfg.daemonName}"'';
        RemainAfterExit = true;
        Restart = "on-failure";
        User = cfg.user;
      };
    };

    services.nginx = mkIf cfg.nginx.enable {
      enable = true;
      recommendedProxySettings = true;
      recommendedGzipSettings = true;
      recommendedTlsSettings = true;
      virtualHosts.${cfg.nginx.domain} = {
        enableACME = cfg.nginx.enableACME;
        forceSSL = cfg.nginx.forceSSL;
        locations."/" = {
          proxyPass = "http://localhost:${toString cfg.port}";
          basicAuthFile = cfg.nginx.basicAuthFile;
          extraConfig = ''
            add_header 'Access-Control-Allow-Origin' '${cfg.nginx.corsAllowOrigin}' always;
            add_header 'Access-Control-Allow-Methods' '${cfg.nginx.corsAllowMethods}' always;
          '';
        };
      };
    };
  };
}
