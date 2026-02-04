;;; org-agenda-api-core.el --- Core utilities for org-agenda-api -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison
;; Author: Ivan Malison <IvanMalison@gmail.com>

;;; Commentary:
;; Core utilities: logging, caching, configuration, git refresh, worker lifecycle.

;;; Code:

(require 'cl-lib)
(require 'lisp-mnt)
(require 'org-agenda)
(require 'org-archive)

;;; Version

(defconst org-agenda-api-version
  (or (getenv "ORG_AGENDA_API_VERSION")
      (lm-version (or load-file-name
                      (locate-library "org-agenda-api")
                      buffer-file-name))
      "unknown")
  "Version of org-agenda-api.
Read from ORG_AGENDA_API_VERSION env var (set at build time by Nix flake),
or extracted from package header at load time.")

;;; Logging

(defcustom org-agenda-api-log-level 'info
  "Log level for org-agenda-api.
Levels are: debug, info, warn, error."
  :type '(choice (const :tag "Debug" debug)
                 (const :tag "Info" info)
                 (const :tag "Warn" warn)
                 (const :tag "Error" error))
  :group 'org-agenda-api)

(defun org-agenda-api--log (level format-string &rest args)
  "Log a message at LEVEL using FORMAT-STRING and ARGS.
Only logs if LEVEL is at or above `org-agenda-api-log-level'."
  (let ((levels '(debug info warn error))
        (prefix (pcase level
                  ('debug "[DEBUG]")
                  ('info "[INFO]")
                  ('warn "[WARN]")
                  ('error "[ERROR]"))))
    (when (>= (cl-position level levels)
              (cl-position org-agenda-api-log-level levels))
      (apply #'message (concat "org-agenda-api " prefix " " format-string) args))))

(defun org-agenda-api--log-request (endpoint method)
  "Log an incoming request to ENDPOINT with METHOD."
  (org-agenda-api--log 'info "Request: %s %s" method endpoint))

(defun org-agenda-api--log-response (endpoint status duration-ms)
  "Log a response for ENDPOINT with STATUS and DURATION-MS."
  (org-agenda-api--log 'info "Response: %s -> %s (%dms)" endpoint status duration-ms))

(defun org-agenda-api--log-error (endpoint error-msg)
  "Log an error for ENDPOINT with ERROR-MSG."
  (org-agenda-api--log 'error "Error in %s: %s" endpoint error-msg))

(defun org-agenda-api--capture-backtrace ()
  "Capture current backtrace as a string.
Returns the backtrace excluding internal logging frames."
  (let ((backtrace-str
         (if (fboundp 'backtrace-to-string)
             ;; Emacs 29+ has backtrace-to-string
             (backtrace-to-string)
           ;; Fallback for older Emacs - use with-output-to-string
           ;; which properly binds standard-output to capture the backtrace
           (with-output-to-string
             (backtrace)))))
    ;; Filter out internal frames for cleaner output
    (with-temp-buffer
      (insert backtrace-str)
      (goto-char (point-min))
      ;; Skip frames from our logging functions
      (let ((skip-patterns '("org-agenda-api--capture-backtrace"
                             "org-agenda-api--log-error-with-backtrace")))
        (while (and (not (eobp))
                    (cl-some (lambda (pat)
                               (looking-at (concat ".*" (regexp-quote pat))))
                             skip-patterns))
          (forward-line 1)))
      (buffer-substring (point) (point-max)))))

(defun org-agenda-api--log-error-with-backtrace (endpoint err)
  "Log an error for ENDPOINT with full backtrace.
ERR should be the error caught by condition-case."
  (let ((error-msg (error-message-string err))
        (backtrace (org-agenda-api--capture-backtrace)))
    (org-agenda-api--log 'error "Error in %s: %s" endpoint error-msg)
    (org-agenda-api--log 'error "Backtrace:\n%s" backtrace)))

;;; Customization

(defgroup org-agenda-api nil
  "JSON HTTP API for org-agenda."
  :group 'org
  :prefix "org-agenda-api-")

(defcustom org-agenda-api-port 2025
  "Port number for the HTTP server."
  :type 'integer
  :group 'org-agenda-api)

(defcustom org-agenda-api-capture-templates nil
  "Capture templates registered for API use.
Each entry is a list of (KEY . PLIST) where PLIST contains:
  :name     - Human-readable name for the template
  :template - An org-capture template specification
  :prompts  - List of prompt definitions for API parameters
              Each prompt is (NAME . PLIST) with :type and :required"
  :type 'sexp
  :group 'org-agenda-api)

(defcustom org-agenda-api-max-requests nil
  "Maximum requests before worker exits for restart.
Set to nil to disable (worker runs forever).
When set, worker will exit gracefully after handling this many requests,
allowing supervisord/process manager to restart it."
  :type '(choice (const :tag "Disabled" nil)
                 (integer :tag "Max requests"))
  :group 'org-agenda-api)

(defcustom org-agenda-api-max-lifetime nil
  "Maximum lifetime in seconds before worker exits for restart.
Set to nil to disable. When set, worker will exit after this many
seconds, checked after each request completes."
  :type '(choice (const :tag "Disabled" nil)
                 (integer :tag "Max seconds"))
  :group 'org-agenda-api)

(defcustom org-agenda-api-category-strategies nil
  "Category strategies registered for API use.
Each entry can be either:
  (NAME . STRATEGY) - simple form using default template and prompts
  (NAME :strategy STRATEGY :template TEMPLATE :prompts PROMPTS) - full form

Where:
  NAME     - A string identifying the strategy type
  STRATEGY - An instance of an occ-strategy subclass (from org-category-capture)
  TEMPLATE - Optional capture template string (default: \"* TODO %?\\n\")
  PROMPTS  - Optional list of prompt definitions for API parameters
             Each prompt is (NAME :type TYPE :required BOOL)
             Types: string, date, tags

These strategies expose categories through the API.  When org-category-capture
or org-project-capture is loaded, you can register strategies like:

  ;; Simple form (uses default template and prompts):
  (setq org-agenda-api-category-strategies
        \\='((\"projects\" . org-project-capture-strategy)))

  ;; With custom template and prompts:
  (setq org-agenda-api-category-strategies
        \\=`((\"projects\" :strategy ,org-project-capture-strategy
                       :template ,org-project-capture-capture-template
                       :prompts ((\"Title\" :type string :required t)
                                 (\"Scheduled\" :type date :required nil)))))

The API will then expose endpoints:
  GET /category-types - list registered strategy types (includes prompts)
  GET /categories?type=NAME - get categories for a strategy
  GET /category-tasks?type=NAME&category=CAT - get tasks in a category
  POST /category-capture - capture a new entry to a category"
  :type '(alist :key-type string :value-type sexp)
  :group 'org-agenda-api)

(defcustom org-agenda-api-auto-add-org-id t
  "Automatically add org-id to entries that don't have one.
When non-nil (the default), entries without an ID property will
automatically have one generated and saved when they are processed
for notifications. This provides stable identifiers for API consumers."
  :type 'boolean
  :group 'org-agenda-api)

(defcustom org-agenda-api-exposed-functions nil
  "List of elisp functions exposed for remote execution via the API.
Each entry can be either:
  - A symbol: function name (display name derived from symbol)
  - A list: (SYMBOL :name \"Display Name\")

Only functions in this whitelist can be called via the /call-function endpoint.

Example:
  (setq org-agenda-api-exposed-functions
        \\='(org-reschedule-past-to-today
          (imalison:lower-todo-priorities :name \"Lower Priorities\")))"
  :type '(repeat (choice symbol (list symbol (plist :key-type keyword :value-type string))))
  :group 'org-agenda-api)

(defcustom org-agenda-api-archive-files nil
  "Archive files or directories to include when archives are requested.
Each entry may be a file path or a directory. Directories are scanned for
files matching `org-agenda-api-archive-file-pattern'."
  :type '(repeat string)
  :group 'org-agenda-api)

(defcustom org-agenda-api-archive-file-pattern "\\.org_archive\\'"
  "Regexp used to identify archive files within archive directories."
  :type 'regexp
  :group 'org-agenda-api)

(defcustom org-agenda-api-include-archives-default nil
  "When non-nil, include archive files/trees by default for read endpoints.
This can be overridden per-request via the `include_archives' query param."
  :type 'boolean
  :group 'org-agenda-api)

(defun org-agenda-api--get-exposed-functions ()
  "Return exposed functions as a list of alists for JSON encoding.
Each entry has \"id\" (function symbol name) and \"name\" (display name)."
  (mapcar (lambda (entry)
            (if (symbolp entry)
                `(("id" . ,(symbol-name entry))
                  ("name" . ,(symbol-name entry)))
              (let* ((sym (car entry))
                     (plist (cdr entry))
                     (name (or (plist-get plist :name) (symbol-name sym))))
                `(("id" . ,(symbol-name sym))
                  ("name" . ,name)))))
          org-agenda-api-exposed-functions))

(defun org-agenda-api--function-whitelisted-p (func-name)
  "Return t if FUNC-NAME (string) is in the exposed functions whitelist."
  (let ((func-sym (intern func-name)))
    (cl-some (lambda (entry)
               (if (symbolp entry)
                   (eq entry func-sym)
                 (eq (car entry) func-sym)))
             org-agenda-api-exposed-functions)))

;;; Archive handling

(defun org-agenda-api--param-truthy-p (value)
  "Return t if VALUE (string) represents a truthy query param."
  (member value '("true" "1" "t" "yes")))

(defun org-agenda-api--param-falsey-p (value)
  "Return t if VALUE (string) represents a falsey query param."
  (member value '("false" "0" "nil" "no")))

(defun org-agenda-api--include-archives-p (param)
  "Return t if archives should be included given PARAM.
PARAM is a query param string for `include_archives'."
  (cond
   ((org-agenda-api--param-truthy-p param) t)
   ((org-agenda-api--param-falsey-p param) nil)
   (t org-agenda-api-include-archives-default)))

(defun org-agenda-api--archive-location-file (agenda-file)
  "Return archive file path for AGENDA-FILE based on `org-archive-location'.
Returns nil for in-file archive locations."
  (when (boundp 'org-archive-location)
    (let ((archive-location org-archive-location))
      (when (and agenda-file (file-exists-p agenda-file))
        (with-current-buffer (find-file-noselect agenda-file)
          (setq archive-location org-archive-location)))
      (when (stringp archive-location)
        (let* ((location (car (split-string archive-location "::")))
               (location (or location "")))
          (unless (string= location "")
            (let* ((base (file-name-nondirectory (expand-file-name agenda-file)))
                   (target (replace-regexp-in-string "%s" base location t t))
                   (expanded (expand-file-name target
                                               (file-name-directory (expand-file-name agenda-file)))))
              (unless (string= expanded (expand-file-name agenda-file))
                expanded))))))))

(defun org-agenda-api--expand-archive-entry (entry)
  "Expand archive ENTRY to a list of file paths."
  (cond
   ((null entry) nil)
   ((file-directory-p entry)
    (directory-files entry t org-agenda-api-archive-file-pattern))
   (t (list entry))))

(defun org-agenda-api--get-archive-files (&optional agenda-files)
  "Return archive file paths derived from config and AGENDA-FILES."
  (let ((archives nil))
    ;; Explicit archive files/directories
    (dolist (entry org-agenda-api-archive-files)
      (setq archives (nconc archives (org-agenda-api--expand-archive-entry entry))))
    ;; Archives derived from org-archive-location
    (dolist (file (or agenda-files org-agenda-files))
      (let ((archive-file (org-agenda-api--archive-location-file file)))
        (when archive-file
          (push archive-file archives))))
    (setq archives (mapcar #'expand-file-name archives))
    (setq archives (cl-remove-if-not #'file-exists-p archives))
    (delete-dups archives)))

(defun org-agenda-api--agenda-files-with-archives (&optional agenda-files)
  "Return AGENDA-FILES plus any discovered archive files."
  (let* ((base-files (mapcar #'expand-file-name (or agenda-files org-agenda-files)))
         (archive-files (org-agenda-api--get-archive-files base-files)))
    (delete-dups (append base-files archive-files))))

(defun org-agenda-api--ensure-org-mode (files)
  "Ensure FILES are opened in Org mode to keep element cache active."
  (dolist (file files)
    (when (and file (file-exists-p file))
      (with-current-buffer (find-file-noselect file)
        (unless (derived-mode-p 'org-mode)
          (org-mode))))))

(defmacro org-agenda-api--with-archives (include-archives &rest body)
  "Execute BODY with archive files/trees included when INCLUDE-ARCHIVES is non-nil."
  (declare (indent 1))
  `(if ,include-archives
       (let ((orig-files org-agenda-files)
             (orig-skip org-agenda-skip-archived-trees)
             (orig-archives-mode (and (boundp 'org-agenda-archives-mode)
                                      org-agenda-archives-mode)))
         (unwind-protect
             (progn
               (setq org-agenda-files (org-agenda-api--agenda-files-with-archives orig-files)
                     org-agenda-skip-archived-trees nil)
               (org-agenda-api--ensure-org-mode org-agenda-files)
               (when (boundp 'org-agenda-archives-mode)
                 (setq org-agenda-archives-mode t))
               ,@body)
           (setq org-agenda-files orig-files
                 org-agenda-skip-archived-trees orig-skip)
           (when (boundp 'org-agenda-archives-mode)
             (setq org-agenda-archives-mode orig-archives-mode))))
     (progn ,@body)))

;;; Worker Lifecycle

(defvar org-agenda-api--request-count 0
  "Number of requests handled by this worker.")

(defvar org-agenda-api--start-time nil
  "Time when this worker started.")

(defun org-agenda-api--check-worker-lifecycle ()
  "Check if worker should exit based on max-requests or max-lifetime.
Called after each request completes. Exits gracefully if limit reached."
  (let ((should-exit nil)
        (reason nil))
    ;; Check request count
    (when (and org-agenda-api-max-requests
               (>= org-agenda-api--request-count org-agenda-api-max-requests))
      (setq should-exit t
            reason (format "max requests reached (%d)" org-agenda-api--request-count)))
    ;; Check lifetime
    (when (and org-agenda-api-max-lifetime
               org-agenda-api--start-time
               (>= (float-time (time-subtract (current-time) org-agenda-api--start-time))
                   org-agenda-api-max-lifetime))
      (setq should-exit t
            reason (format "max lifetime reached (%ds)" org-agenda-api-max-lifetime)))
    ;; Exit if needed
    (when should-exit
      (message "org-agenda-api: worker exiting (%s)" reason)
      ;; Use a timer to exit after response is fully sent
      (run-at-time 0.1 nil #'kill-emacs 0))))

(defun org-agenda-api--track-request ()
  "Increment request counter and check lifecycle.
Call this at the end of each servlet."
  (cl-incf org-agenda-api--request-count)
  (org-agenda-api--check-worker-lifecycle))

;;; Caching

(defvar org-agenda-api--todos-cache nil
  "Cached TODO items from last computation.")

(defvar org-agenda-api--cache-mtime nil
  "Maximum modification time of org files when cache was built.")

(defun org-agenda-api--get-max-mtime ()
  "Get the maximum modification time across all `org-agenda-files'."
  (if (null org-agenda-files)
      0
    (apply #'max
           (mapcar (lambda (file)
                     (if (file-exists-p file)
                         (float-time (file-attribute-modification-time
                                      (file-attributes file)))
                       0))
                   org-agenda-files))))

(defun org-agenda-api--cache-valid-p ()
  "Return t if the TODO cache is still valid."
  (and org-agenda-api--todos-cache
       org-agenda-api--cache-mtime
       (<= (org-agenda-api--get-max-mtime)
           org-agenda-api--cache-mtime)))

(defun org-agenda-api--invalidate-cache ()
  "Invalidate the TODO cache."
  (setq org-agenda-api--todos-cache nil
        org-agenda-api--cache-mtime nil))

;;; Git Refresh

(defun org-agenda-api--get-git-repos-for-agenda-files ()
  "Get unique git repository roots for all `org-agenda-files'."
  (let ((repos nil))
    (dolist (file org-agenda-files)
      (when (file-exists-p file)
        (let ((dir (file-name-directory (expand-file-name file))))
          (when dir
            (let ((git-root (locate-dominating-file dir ".git")))
              (when git-root
                (let ((normalized (expand-file-name git-root)))
                  (unless (member normalized repos)
                    (push normalized repos)))))))))
    repos))

(defun org-agenda-api--git-refresh-repo (repo-path)
  "Run git pull in REPO-PATH. Returns alist with result."
  (let ((default-directory repo-path))
    (condition-case err
        (let ((output (shell-command-to-string "git pull --ff-only 2>&1")))
          `(("repo" . ,repo-path)
            ("status" . "success")
            ("output" . ,(string-trim output))))
      (error
       (org-agenda-api--log-error-with-backtrace "git-refresh" err)
       `(("repo" . ,repo-path)
         ("status" . "error")
         ("message" . ,(error-message-string err)))))))

(defun org-agenda-api--git-refresh-all ()
  "Refresh all git repos containing agenda files.
Returns list of results for each repo."
  (let ((repos (org-agenda-api--get-git-repos-for-agenda-files)))
    (when repos
      (org-agenda-api--invalidate-cache)
      (mapcar #'org-agenda-api--git-refresh-repo repos))))

(defun org-agenda-api--trigger-sync ()
  "Touch an org file to trigger git-sync-rs to sync.
Returns alist with status and touched file path."
  (let ((file (car org-agenda-files)))
    (if file
        (let ((expanded-file (expand-file-name file)))
          (if (file-exists-p expanded-file)
              (progn
                (set-file-times expanded-file)
                (org-agenda-api--log 'info "trigger-sync: touched %s" expanded-file)
                `(("status" . "success")
                  ("touchedFile" . ,expanded-file)
                  ("message" . "File touched to trigger git-sync-rs")))
            `(("status" . "error")
              ("message" . ,(format "File does not exist: %s" expanded-file)))))
      `(("status" . "error")
        ("message" . "No org-agenda-files configured")))))

;;; Utility Functions

(defun org-agenda-api--plist-to-alist (plist)
  "Convert PLIST to an alist for JSON encoding.
Converts :key to \"key\" string."
  (let ((result nil))
    (while plist
      (let ((key (substring (symbol-name (car plist)) 1))  ; Remove leading :
            (value (cadr plist)))
        (push (cons key value) result))
      (setq plist (cddr plist)))
    (nreverse result)))

(provide 'org-agenda-api-core)
;;; org-agenda-api-core.el ends here
