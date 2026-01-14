;;; container-init.el --- Container initialization for org-agenda-api -*- lexical-binding: t; -*-

;;; Commentary:
;; This file is loaded by the org-agenda-api container to configure
;; org-mode and start the API server. Configuration is read from
;; environment variables.

;;; Code:

(require 'org)
(require 'org-agenda)

;; org-agenda-files should be set by custom elisp
;; We don't set a default here to avoid interfering with custom config

;; Set inbox file for captures
(setq org-agenda-api-inbox-file
      (or (getenv "ORG_INBOX_FILE") "/data/org/inbox.org"))

;; Set port from environment
(setq org-agenda-api-port
      (string-to-number (or (getenv "ORG_API_PORT") "2025")))

;; Configure worker lifecycle (for graceful restarts)
;; Workers exit after N requests or N seconds, allowing supervisord to restart them
(let ((max-requests (getenv "ORG_API_MAX_REQUESTS"))
      (max-lifetime (getenv "ORG_API_MAX_LIFETIME")))
  (when max-requests
    (setq org-agenda-api-max-requests (string-to-number max-requests)))
  (when max-lifetime
    (setq org-agenda-api-max-lifetime (string-to-number max-lifetime))))

;; Load custom elisp if specified (file path)
(let ((custom-elisp-file (getenv "ORG_API_CUSTOM_ELISP")))
  (when (and custom-elisp-file (file-exists-p custom-elisp-file))
    (load custom-elisp-file)))

;; Evaluate inline custom elisp if specified (for runtime configuration)
;; Wrap content in progn to support multiple expressions
(let ((custom-elisp-content (getenv "ORG_API_CUSTOM_ELISP_CONTENT")))
  (when (and custom-elisp-content (not (string-empty-p custom-elisp-content)))
    (eval (car (read-from-string (format "(progn %s)" custom-elisp-content))))))

;; Start the API server
(org-agenda-api-start)

(provide 'container-init)
;;; container-init.el ends here
