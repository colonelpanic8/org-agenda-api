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

;; Load dependencies and the package
(require 'org)
(require 'org-agenda)
(require 'simple-httpd)
(require 'org-agenda-api)

;; Configure org-agenda-files to point to test directory
;; Expand directory to list of .org files since org-agenda-api
;; expects file paths, not directories
(setq org-agenda-files
      (directory-files test-org-dir t "\\.org$"))

;; Override calendar-current-date if a fake date is set (for deterministic tests)
;; Format: "YYYY-MM-DD" e.g., "2024-06-15"
(when test-fake-date
  (let* ((parts (split-string test-fake-date "-"))
         (year (string-to-number (nth 0 parts)))
         (month (string-to-number (nth 1 parts)))
         (day (string-to-number (nth 2 parts))))
    (defun calendar-current-date ()
      "Return a fake date for testing."
      (list month day year))))

;; Configure the API
(setq org-agenda-api-port test-port)
(when test-inbox
  (setq org-agenda-api-inbox-file test-inbox))

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
