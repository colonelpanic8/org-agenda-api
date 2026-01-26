;;; run-emacs-server.el --- Bootstrap script for testing org-agenda-api -*- lexical-binding: t; -*-

;; This script is used by pytest to start an Emacs instance with the
;; org-agenda-api server running. It reads configuration from environment
;; variables and keeps Emacs alive until killed.

;;; Code:

;; Get configuration from environment
(defvar test-org-dir (getenv "ORG_AGENDA_API_TEST_ORG_DIR"))
(defvar test-port (string-to-number (or (getenv "ORG_AGENDA_API_TEST_PORT") "9876")))
(defvar test-inbox (getenv "ORG_AGENDA_API_TEST_INBOX"))
(defvar test-fake-date (getenv "ORG_AGENDA_API_TEST_FAKE_DATE"))

;; Validate required env vars
(unless test-org-dir
  (error "ORG_AGENDA_API_TEST_ORG_DIR environment variable is required"))

;; Add the package directory to load path
(add-to-list 'load-path (or (getenv "ORG_AGENDA_API_PACKAGE_DIR")
                            (file-name-directory
                             (directory-file-name
                              (file-name-directory load-file-name)))))

;; Load dependencies
(require 'org)
(require 'org-agenda)
(require 'simple-httpd)

;; org-wild-notifier is optional - only load if available
;; It provides notification-related features
(when (require 'org-wild-notifier nil t)
  (message "org-wild-notifier loaded"))

;; Override calendar-current-date and org-today BEFORE loading org-agenda-api
;; and BEFORE setting org-agenda-files. This ensures all date-related
;; operations use the fake date for deterministic tests.
;; Format: "YYYY-MM-DD" e.g., "2024-06-15"
(when test-fake-date
  (let* ((parts (split-string test-fake-date "-"))
         (year (string-to-number (nth 0 parts)))
         (month (string-to-number (nth 1 parts)))
         (day (string-to-number (nth 2 parts)))
         ;; Calculate the absolute day number for the fake date
         (absolute-day (calendar-absolute-from-gregorian (list month day year))))
    (defun calendar-current-date ()
      "Return a fake date for testing."
      (list month day year))
    ;; Also override org-today which is used internally by org-agenda
    ;; to determine which items are scheduled/deadline for "today"
    (defun org-today ()
      "Return the fake date as an absolute day number for testing."
      absolute-day)
    (message "Test mode: Using fake date %s (absolute day %d)" test-fake-date absolute-day)))

;; Now load org-agenda-api (after date overrides are in place)
(require 'org-agenda-api)

;; Debug logging can cause performance issues/hangs, so leave at default level
;; (setq org-agenda-api-log-level 'debug)

;; Load the window-habit integration module if org-window-habit is available
(when (require 'org-window-habit nil t)
  (require 'org-agenda-api-window-habit)
  (org-window-habit-mode 1)
  (message "org-window-habit-mode enabled for testing"))

;; Configure org-agenda-files to point to test directory
;; Expand directory to list of .org files since org-agenda-api
;; expects file paths, not directories
(setq org-agenda-files
      (directory-files test-org-dir t "\\.org$"))

;; Configure TODO states to include NEXT, STARTED, etc.
;; The ! marker means log a timestamp when entering that state
(setq org-todo-keywords
      '((sequence "TODO(t!)" "NEXT(n!)" "STARTED(s!)" "WAITING(w!)" "|" "DONE(d!)" "CANCELLED(c!)")))

;; Enable LOGBOOK drawer for state change logging
(setq org-log-into-drawer t)

;; Enable CLOSED timestamp when completing TODOs
;; This is required for include_completed feature to work correctly
(setq org-log-done 'time)

;; Enable logging for repeating tasks (habits)
;; This creates LOGBOOK entries when completing repeating tasks
(setq org-log-repeat 'time)

;; Configure custom agenda commands for testing
(setq org-agenda-custom-commands
      '(("n" "Next actions" todo "NEXT")
        ("s" "Started tasks" todo "STARTED")
        ("w" "Waiting tasks" todo "WAITING")
        ("h" "High priority" tags-todo "+PRIORITY=\"A\"")
        ("W" "Work tasks" tags-todo "+work")))

;; Configure the API
(setq org-agenda-api-port test-port)
(when test-inbox
  (setq org-agenda-api-inbox-file test-inbox))

;; Configure test capture templates for API use
;; These use org-capture template format with %^{Prompt} for interactive fields
(setq org-agenda-api-capture-templates
      `(("todo"
         :name "Todo"
         :template ("t" "Todo" entry (file ,test-inbox)
                    "* TODO %^{Title}\n"
                    :immediate-finish t)
         :prompts (("Title" :type string :required t)))
        ;; Template with SCHEDULED: %t to test date-only behavior
        ("scheduled-today"
         :name "Scheduled Today"
         :template ("s" "Scheduled Today" entry (file ,test-inbox)
                    "* TODO %^{Title}\nSCHEDULED: %t\n"
                    :immediate-finish t)
         :prompts (("Title" :type string :required t)))
        ("scheduled-todo"
         :name "Scheduled Todo"
         :template ("s" "Scheduled" entry (file ,test-inbox)
                    "* TODO %^{Title}\nSCHEDULED: %^{When}t\n"
                    :immediate-finish t)
         :prompts (("Title" :type string :required t)
                   ("When" :type date :required t)))
        ("tagged-todo"
         :name "Tagged Todo"
         :template ("g" "Tagged" entry (file ,test-inbox)
                    "* TODO %^{Title} %^{Tags}g\n"
                    :immediate-finish t)
         :prompts (("Title" :type string :required t)
                   ("Tags" :type tags :required nil)))
        ("note"
         :name "Note"
         :template ("n" "Note" entry (file ,test-inbox)
                    "* %^{Title}\n[%U]\n\n%?"
                    :immediate-finish t)
         :prompts (("Title" :type string :required t)))
        ;; Template with %(sexp) expressions for testing org-capture-fill-template
        ("todo-with-id"
         :name "Todo with ID"
         :template ("i" "Todo with ID" entry (file ,test-inbox)
                    "* TODO %^{Title}\n:PROPERTIES:\n:ID: %(org-id-new)\n:CREATED: %U\n:END:\n"
                    :immediate-finish t)
         :prompts (("Title" :type string :required t)))
        ;; Template with %(format-time-string) for scheduled date
        ("scheduled-auto"
         :name "Scheduled Today Auto"
         :template ("a" "Scheduled Auto" entry (file ,test-inbox)
                    "* TODO %^{Title}\nSCHEDULED: %(format-time-string \"<%Y-%m-%d %a>\")\n:PROPERTIES:\n:ID: %(org-id-new)\n:END:\n"
                    :immediate-finish t)
         :prompts (("Title" :type string :required t)))
        ;; Template with multiple %(sexp) expressions
        ("full-template"
         :name "Full Template"
         :template ("f" "Full" entry (file ,test-inbox)
                    "* TODO %^{Title}\nSCHEDULED: %(format-time-string \"<%Y-%m-%d %a>\")\n:PROPERTIES:\n:ID: %(org-id-new)\n:CREATED: %U\n:EFFORT: %(number-to-string 30)\n:END:\n"
                    :immediate-finish t)
         :prompts (("Title" :type string :required t)))))

;; Set up test category strategy if org-category-capture is available
(when (require 'org-category-capture nil t)
  (require 'org-project-capture nil t)
  ;; Create a simple single-file strategy for testing
  (let ((projects-file (expand-file-name "projects.org" test-org-dir)))
    ;; Create projects file if it doesn't exist
    (unless (file-exists-p projects-file)
      (with-temp-file projects-file
        (insert "#+TITLE: Test Projects\n\n"
                "* Project Alpha\n"
                "* Project Beta\n")))
    ;; Set up the strategy
    (setq org-project-capture-projects-file projects-file)
    (let ((test-strategy (make-instance 'org-project-capture-single-file-strategy)))
      (setq org-agenda-api-category-strategies
            `(("projects" . ,test-strategy)))
      (message "Category strategy registered: projects -> %s" projects-file))))

;; Start the server
(org-agenda-api-start)

;; Print ready message so pytest can detect when server is up
(message "ORG-AGENDA-API-READY port=%d" test-port)

;; Keep Emacs alive and process network events
;; In batch mode, we need to explicitly accept process output
;; to allow the HTTP server to handle incoming connections
(while t
  (accept-process-output nil 1))

;;; run-emacs-server.el ends here
