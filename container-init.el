;;; container-init.el --- Container initialization for org-agenda-api -*- lexical-binding: t; -*-

;;; Commentary:
;; This file is loaded by the org-agenda-api container to configure
;; org-mode and start the API server. Configuration is read from
;; environment variables.

;;; Code:

(require 'org)
(require 'org-agenda)

;; Helper function to expand directories to org files
(defun org-agenda-api--expand-to-org-files (paths)
  "Expand PATHS to a list of org files.
If a path is a directory, find all .org files in it recursively.
If a path is a file, include it directly."
  (cl-loop for path in paths
           if (file-directory-p path)
           append (directory-files-recursively path "\\.org$")
           else if (file-exists-p path)
           collect path))

;; Set org-agenda-files from environment or default
(setq org-agenda-files
      (org-agenda-api--expand-to-org-files
       (let ((env-files (getenv "ORG_AGENDA_FILES")))
         (if env-files
             (split-string env-files ":")
           '("/data/org")))))

;; Set inbox file for captures
(setq org-agenda-api-inbox-file
      (or (getenv "ORG_INBOX_FILE") "/data/org/inbox.org"))

;; Set port from environment
(setq org-agenda-api-port
      (string-to-number (or (getenv "ORG_API_PORT") "2025")))

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
