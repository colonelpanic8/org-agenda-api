;;; container-init.el --- Container initialization for org-agenda-api -*- lexical-binding: t; -*-

;;; Commentary:
;; This file is loaded by the org-agenda-api container to configure
;; org-mode and start the API server. Configuration is read from
;; environment variables.

;;; Code:

(require 'org)
(require 'org-agenda)

;; === Container Logging Configuration ===

;; Enable debug-on-error to get tracebacks when errors occur
(setq debug-on-error t)

;; Log all Emacs messages to stderr so they appear in container logs
(defun org-agenda-api--log-to-stderr (format-string &rest args)
  "Log FORMAT-STRING with ARGS to stderr for container visibility."
  (let ((msg (apply #'format format-string args)))
    (unless (string-empty-p msg)
      ;; Write to stderr using external-debugging-output
      (princ (format "[emacs] %s\n" msg) #'external-debugging-output))))

;; Advise message function to also log to stderr
(advice-add 'message :after #'org-agenda-api--log-to-stderr)

;; === Auto-revert Configuration ===
;; Automatically reload files when they change on disk (e.g., from git-sync)
(global-auto-revert-mode 1)
(setq auto-revert-interval 5)        ; Check every 5 seconds (was 1, too aggressive)
(setq auto-revert-verbose nil)       ; Suppress "Reverting buffer" messages
(setq auto-revert-check-vc-info nil) ; Don't check VC info on revert (can be slow)

;; === Debug heartbeat timer ===
;; Log every 30 seconds to confirm emacs event loop is responsive
(run-with-timer 30 30
  (lambda ()
    (message "org-agenda-api heartbeat: uptime=%.0fs requests=%d timers=%d"
             (if (boundp 'org-agenda-api--start-time)
                 (float-time (time-subtract (current-time) org-agenda-api--start-time))
               0)
             (if (boundp 'org-agenda-api--request-count)
                 org-agenda-api--request-count
               0)
             (length timer-list))))

;; Log startup
(message "org-agenda-api container-init.el loading...")

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

;; === Auto-discovery of org files ===
;; If org-agenda-files is not set after loading custom elisp,
;; auto-discover org files from the data directory

(defun org-agenda-api--discover-org-files ()
  "Discover org files in /data directory.
Searches for .org files in:
1. Repo paths from GIT_SYNC_REPOSITORIES env var
2. /data/org (legacy single-repo path) if it's a git repo
3. All subdirectories of /data as fallback"
  (let ((repos-json (getenv "GIT_SYNC_REPOSITORIES"))
        (search-dirs nil)
        (org-files nil))
    (cond
     ;; Multi-repo mode: parse repo paths from JSON
     (repos-json
      (condition-case nil
          (let ((repos (json-parse-string repos-json :array-type 'list)))
            (dolist (repo repos)
              (let ((path (gethash "path" repo)))
                (when path
                  (push (concat "/data/" path) search-dirs)))))
        (error
         (message "Warning: Failed to parse GIT_SYNC_REPOSITORIES"))))
     ;; Legacy: use /data/org if it's a git repo
     ((file-directory-p "/data/org/.git")
      (push "/data/org" search-dirs)))
    ;; Always also search /data for any other org files
    (push "/data" search-dirs)
    (setq search-dirs (delete-dups search-dirs))
    ;; Find all .org files in search directories
    (dolist (dir search-dirs)
      (when (file-directory-p dir)
        (setq org-files
              (append org-files
                      (directory-files-recursively dir "\\.org$")))))
    ;; Remove duplicates and filter out common non-agenda files
    (delete-dups
     (cl-remove-if
      (lambda (f)
        (or (string-match-p "/\\.git/" f)
            (string-match-p "/node_modules/" f)
            (string-match-p "/straight/" f)
            (string-match-p "#" f)))
      org-files))))

(unless org-agenda-files
  (message "org-agenda-files not set, auto-discovering org files...")
  (let ((discovered (org-agenda-api--discover-org-files)))
    (if discovered
        (progn
          (setq org-agenda-files discovered)
          (message "Auto-discovered %d org files" (length discovered))
          ;; Set inbox file to first repo's inbox.org if not explicitly set
          (unless (getenv "ORG_INBOX_FILE")
            (let* ((first-file (car discovered))
                   (first-dir (file-name-directory first-file))
                   (inbox-candidate (expand-file-name "inbox.org" first-dir)))
              (setq org-agenda-api-inbox-file inbox-candidate)
              (message "Auto-set inbox file to: %s" inbox-candidate))))
      (message "Warning: No org files found in /data"))))

;; === Default Capture Templates ===
;; Set up default capture templates if not already configured
(unless org-agenda-api-capture-templates
  (setq org-agenda-api-capture-templates
        `(("todo"
           :name "Todo"
           :template ("t" "Todo" entry (file ,org-agenda-api-inbox-file)
                      "* TODO %^{Title}\n"
                      :immediate-finish t)
           :prompts (("Title" :type string :required t)))
          ("scheduled-todo"
           :name "Scheduled Todo"
           :template ("s" "Scheduled" entry (file ,org-agenda-api-inbox-file)
                      "* TODO %^{Title}\nSCHEDULED: %^{When}t\n"
                      :immediate-finish t)
           :prompts (("Title" :type string :required t)
                     ("When" :type date :required t)))
          ("deadline-todo"
           :name "Deadline Todo"
           :template ("d" "Deadline" entry (file ,org-agenda-api-inbox-file)
                      "* TODO %^{Title}\nDEADLINE: %^{When}t\n"
                      :immediate-finish t)
           :prompts (("Title" :type string :required t)
                     ("When" :type date :required t)))))
  (message "Configured %d default capture templates" (length org-agenda-api-capture-templates)))

;; Log configuration summary
(message "org-agenda-api configuration:")
(message "  org-agenda-files: %s" org-agenda-files)
(message "  inbox-file: %s" org-agenda-api-inbox-file)
(message "  port: %d" org-agenda-api-port)
(message "  capture-templates: %s" (mapcar #'car org-agenda-api-capture-templates))

;; Start the API server
(message "Starting org-agenda-api server...")
(org-agenda-api-start)
(message "org-agenda-api server started successfully on port %d" org-agenda-api-port)

(provide 'container-init)
;;; container-init.el ends here
