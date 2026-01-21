;;; org-agenda-api.el --- JSON HTTP API for org-agenda -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison

;; Author: Ivan Malison <IvanMalison@gmail.com>
;; URL: https://github.com/IvanMalison/org-agenda-api
;; Version: 2.1.0
;; Package-Requires: ((emacs "26.1") (simple-httpd "1.5.1"))
;; Keywords: org, agenda, api, json

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides a JSON HTTP API for accessing org-agenda data.
;; It exposes endpoints for retrieving todos and scheduled items.
;;
;; Usage:
;;   (require 'org-agenda-api)
;;   (org-agenda-api-start)
;;
;; Endpoints:
;;   GET /get-all-todos - Returns all TODO items from agenda files
;;       ?refresh=true - Git pull repos containing agenda files first
;;   GET /agenda - Returns org-agenda entriesg
;;       ?span=day|week - Agenda span (default: day)
;;       ?refresh=true - Git pull repos containing agenda files first
;;   GET /get-todays-agenda - Returns scheduled/deadlined items for today
;;   GET /health - Health check endpoint for monitoring (nginx, supervisord)
;;   GET /agenda-files - Returns list of org-agenda-files
;;   GET /capture-templates - Returns available capture templates
;;   POST /capture - Create a new entry using a capture template
;;
;; Category Strategy Endpoints (requires org-category-capture):
;;   GET /category-types - Returns list of registered category strategy types
;;   GET /categories - Returns categories for a strategy type
;;       ?type=NAME - Required: the strategy type name
;;       ?existing_only=true - Only return categories with capture locations
;;   GET /category-tasks - Returns tasks for a category
;;       ?type=NAME - Required: the strategy type name
;;       ?category=CAT - Required: the category name
;;   POST /category-capture - Capture a new entry to a category
;;       JSON body: {type, category, title, todo?, scheduled?, deadline?, priority?, tags?, properties?}
;;
;; To register category strategies for the API:
;;   (setq org-agenda-api-category-strategies
;;         '(("projects" . my-project-capture-strategy)))

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-agenda)
(require 'org-element)
(require 'org-capture)
(require 'json)
(require 'simple-httpd)

;;; Version

(require 'lisp-mnt)

(defconst org-agenda-api-version
  (lm-version (or load-file-name
                  (locate-library "org-agenda-api")
                  buffer-file-name))
  "Version of org-agenda-api, read from package header.")

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

;;; Worker Lifecycle

(defvar org-agenda-api--request-count 0
  "Number of requests handled by this worker.")

(defvar org-agenda-api--start-time nil
  "Time when this worker started.")

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

;;; Internal Functions

(defun org-agenda-api--parse-notify-before (value)
  "Parse WILD_NOTIFIER_NOTIFY_BEFORE VALUE into a list of integers.
VALUE can be space or comma separated minutes, e.g., \"10 30 60\" or \"10,30,60\"."
  (when value
    (let ((parts (split-string value "[, \t]+" t)))
      (delq nil (mapcar (lambda (s)
                          (let ((n (string-to-number s)))
                            (when (> n 0) n)))
                        parts)))))

(defun org-agenda-api--get-planning-info ()
  "Get scheduled and deadline info at point.
Return alist with scheduled-time, scheduled-has-time,
deadline-time, deadline-has-time."
  (save-excursion
    (let ((scheduled-time (org-get-scheduled-time (point)))
          (deadline-time (org-get-deadline-time (point)))
          (scheduled-has-time nil)
          (deadline-has-time nil))
      ;; Check the planning line for time components
      (when (or scheduled-time deadline-time)
        (forward-line 1)
        (when (looking-at org-planning-line-re)
          (let ((line (buffer-substring-no-properties (point) (line-end-position))))
            ;; Check SCHEDULED timestamp for time
            (when (and scheduled-time
                       (string-match "SCHEDULED: <[^>]+>" line))
              (let ((ts (match-string 0 line)))
                (setq scheduled-has-time (string-match-p "[0-9]\\{1,2\\}:[0-9]\\{2\\}" ts))))
            ;; Check DEADLINE timestamp for time
            (when (and deadline-time
                       (string-match "DEADLINE: <[^>]+>" line))
              (let ((ts (match-string 0 line)))
                (setq deadline-has-time (string-match-p "[0-9]\\{1,2\\}:[0-9]\\{2\\}" ts)))))))
      `((scheduled-time . ,scheduled-time)
        (scheduled-has-time . ,scheduled-has-time)
        (deadline-time . ,deadline-time)
        (deadline-has-time . ,deadline-has-time)))))

(defun org-agenda-api--format-timestamp (time has-time)
  "Format TIME as ISO string.
If HAS-TIME is non-nil, include time component in local timezone.
Otherwise return date-only format."
  (when time
    (if has-time
        (format-time-string "%Y-%m-%dT%H:%M:%S" time)
      (format-time-string "%Y-%m-%d" time))))

(defun org-agenda-api--extract-date (timestamp)
  "Extract YYYY-MM-DD date portion from TIMESTAMP string.
TIMESTAMP may be in formats like:
  - \"2026-01-19\" (date only)
  - \"2026-01-19T10:00:00\" (with time)
Returns nil if TIMESTAMP is nil."
  (when timestamp
    (substring timestamp 0 (min 10 (length timestamp)))))

(defun org-agenda-api--deduplicate-entries (entries)
  "Remove duplicate entries that point to the same org headline.
When an item has both SCHEDULED and DEADLINE on the same day,
org-agenda shows it twice. This function deduplicates by (file, pos),
keeping only one entry per unique headline location."
  (let ((seen (make-hash-table :test 'equal))
        (result nil))
    (dolist (entry entries)
      (let* ((file (cdr (assoc "file" entry)))
             (pos (cdr (assoc "pos" entry)))
             (key (cons file pos)))
        (unless (gethash key seen)
          (puthash key t seen)
          (push entry result))))
    (nreverse result)))

(defun org-agenda-api--get-all-entry-properties ()
  "Get all properties for the entry at point as an alist.
Returns an alist of (KEY . VALUE) pairs for all properties in the drawer."
  (let ((props (org-entry-properties nil 'standard))
        (result nil))
    (dolist (prop props)
      (let ((key (car prop))
            (value (cdr prop)))
        ;; Include all properties - caller can filter if needed
        (push (cons key value) result)))
    (nreverse result)))

(defun org-agenda-api--get-todo-elements-from-filepath (filepath)
  "Extract all TODO headline elements from FILEPATH.
Uses `org-map-entries' for efficient traversal instead of
expensive `org-element-at-point' calls."
  (with-current-buffer (find-file-noselect filepath)
    (org-map-entries
     (lambda ()
       ;; We're at a headline with a TODO keyword
       ;; Extract properties directly from org functions (much faster than org-element)
       (let* ((todo (org-get-todo-state))
              (title (org-get-heading t t t t))  ; no-tags, no-todo, no-priority, no-comment
              (tags (org-get-tags))
              ;; Only return priority if there's an explicit [#X] cookie in the heading
              (heading-line (buffer-substring (line-beginning-position) (line-end-position)))
              (priority (when (string-match "\\[#\\([A-Z]\\)\\]" heading-line)
                          (match-string 1 heading-line)))
              (level (org-current-level))
              (planning (org-agenda-api--get-planning-info))
              (scheduled-time (alist-get 'scheduled-time planning))
              (scheduled-has-time (alist-get 'scheduled-has-time planning))
              (deadline-time (alist-get 'deadline-time planning))
              (deadline-has-time (alist-get 'deadline-has-time planning))
              (pos (point))
              (org-id (org-entry-get (point) "ID"))
              (olpath (org-get-outline-path t))  ; include current heading
              (notify-before (org-agenda-api--parse-notify-before
                              (org-entry-get (point) "WILD_NOTIFIER_NOTIFY_BEFORE")))
              (all-properties (org-agenda-api--get-all-entry-properties))
              ;; Habit detection - only if the window-habit module is loaded
              (is-window-habit (and (fboundp 'org-agenda-api--is-window-habit-p)
                                    (org-agenda-api--is-window-habit-p)))
              (habit-summary (when (and is-window-habit
                                        (fboundp 'org-agenda-api--get-habit-summary))
                               (org-agenda-api--get-habit-summary))))
         ;; Return an alist directly for JSON encoding (skip org-element overhead)
         `(("todo" . ,todo)
           ("title" . ,title)
           ("tags" . ,(if tags (vconcat tags) nil))
           ("level" . ,level)
           ("scheduled" . ,(org-agenda-api--format-timestamp scheduled-time scheduled-has-time))
           ("deadline" . ,(org-agenda-api--format-timestamp deadline-time deadline-has-time))
           ("file" . ,filepath)
           ("pos" . ,pos)
           ("id" . ,org-id)
           ("olpath" . ,(if olpath (vconcat olpath) nil))
           ("notifyBefore" . ,(when notify-before (vconcat notify-before)))
           ("priority" . ,priority)
           ("properties" . ,all-properties)
           ("isWindowHabit" . ,(if is-window-habit t :json-false))
           ,@(when habit-summary
               `(("habitSummary" . ,habit-summary))))))
     "/!"  ; MATCH: "/!" matches all entries with any TODO keyword
     'file)))

(defun org-agenda-api--get-agenda-todos ()
  "Get all TODO elements from `org-agenda-files'.
Uses caching to avoid re-processing unchanged files."
  (if (org-agenda-api--cache-valid-p)
      org-agenda-api--todos-cache
    ;; Rebuild cache
    (setq org-agenda-api--cache-mtime (org-agenda-api--get-max-mtime)
          org-agenda-api--todos-cache
          (mapcan #'org-agenda-api--get-todo-elements-from-filepath org-agenda-files))
    org-agenda-api--todos-cache))

(defun org-agenda-api--element-to-json (element)
  "Convert org ELEMENT to an alist suitable for JSON encoding."
  (let* ((todo (org-element-property :todo-keyword element))
         (title (org-element-property :raw-value element))
         (tags (org-element-property :tags element))
         (level (org-element-property :level element))
         (scheduled (org-element-property :scheduled element))
         (deadline (org-element-property :deadline element))
         ;; Check if timestamps have time components
         (scheduled-has-time (and scheduled
                                  (org-element-property :hour-start scheduled)))
         (deadline-has-time (and deadline
                                 (org-element-property :hour-start deadline))))
    `(("todo" . ,todo)
      ("title" . ,title)
      ("tags" . ,tags)
      ("level" . ,level)
      ("scheduled" . ,(when scheduled
                        (if scheduled-has-time
                            (org-format-timestamp scheduled "%Y-%m-%dT%H:%M:%S")
                          (org-format-timestamp scheduled "%Y-%m-%d"))))
      ("deadline" . ,(when deadline
                       (if deadline-has-time
                           (org-format-timestamp deadline "%Y-%m-%dT%H:%M:%S")
                         (org-format-timestamp deadline "%Y-%m-%d")))))))

(defun org-agenda-api--item-to-json (item)
  "Convert agenda ITEM to an alist suitable for JSON encoding."
  (let* ((todo (get-text-property 0 'todo-state item))
         (title (substring-no-properties item))
         (tags (get-text-property 0 'tags item))
         (ts-date (get-text-property 0 'ts-date item))
         ;; time-of-day is set when the timestamp has a time, nil otherwise
         (time-of-day (get-text-property 0 'time-of-day item))
         (scheduled (when ts-date
                      (if time-of-day
                          ;; Has time - include it
                          (let* ((hour (/ time-of-day 100))
                                 (minute (mod time-of-day 100))
                                 (date (org-time-from-absolute ts-date)))
                            (format-time-string "%Y-%m-%dT%H:%M:%S"
                                                (encode-time 0 minute hour
                                                             (nth 3 (decode-time date))
                                                             (nth 4 (decode-time date))
                                                             (nth 5 (decode-time date)))))
                        ;; No time - date only
                        (format-time-string "%Y-%m-%d" (org-time-from-absolute ts-date))))))
    `(("todo" . ,todo)
      ("title" . ,title)
      ("tags" . ,tags)
      ("scheduled" . ,scheduled))))

(defun org-agenda-api--get-scheduled-or-deadlined (day filepath)
  "Get scheduled and deadlined items for DAY from FILEPATH."
  (with-current-buffer (find-file-noselect filepath)
    (org-dlet ((date day))
      (setf org-agenda-current-date date)
      (nconc (org-agenda-get-deadlines) (org-agenda-get-scheduled)))))

(defun org-agenda-api--get-today-agenda ()
  "Get all scheduled and deadlined items for today."
  (let ((day (calendar-current-date)))
    (mapcan (lambda (filepath)
              (org-agenda-api--get-scheduled-or-deadlined day filepath))
            org-agenda-files)))

(defun org-agenda-api--get-closed-timestamp ()
  "Get the CLOSED timestamp at point if present.
Returns ISO format timestamp string or nil."
  (save-excursion
    ;; Move to the beginning of the entry to find planning line
    (org-back-to-heading t)
    (forward-line 1)
    (when (looking-at org-planning-line-re)
      (let ((line (buffer-substring-no-properties (point) (line-end-position))))
        ;; Look for CLOSED: [timestamp]
        (when (string-match "CLOSED: \\[\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)[^]]*\\( [0-9]\\{2\\}:[0-9]\\{2\\}\\)?\\]" line)
          (let ((date-part (match-string 1 line))
                (time-part (match-string 2 line)))
            (if time-part
                (format "%sT%s:00" date-part (string-trim time-part))
              date-part)))))))

(defun org-agenda-api--extract-entry-data (marker agenda-line)
  "Extract todo data from the org entry at MARKER.
AGENDA-LINE is the raw agenda display text for reference."
  (when (marker-buffer marker)
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (when (org-at-heading-p)
          (let* ((todo (org-get-todo-state))
                 (title (org-get-heading t t t t))
                 (tags (org-get-tags))
                 (level (org-current-level))
                 (planning (org-agenda-api--get-planning-info))
                 (scheduled-time (alist-get 'scheduled-time planning))
                 (scheduled-has-time (alist-get 'scheduled-has-time planning))
                 (deadline-time (alist-get 'deadline-time planning))
                 (deadline-has-time (alist-get 'deadline-has-time planning))
                 (pos (point))
                 (filepath (buffer-file-name))
                 (org-id (org-entry-get (point) "ID"))
                 (olpath (org-get-outline-path t))
                 (priority (org-entry-get (point) "PRIORITY"))
                 (notify-before (org-agenda-api--parse-notify-before
                                 (org-entry-get (point) "WILD_NOTIFIER_NOTIFY_BEFORE")))
                 (category (org-get-category))
                 (all-properties (org-agenda-api--get-all-entry-properties))
                 ;; Extract CLOSED timestamp directly from the org entry
                 (completed-at (org-agenda-api--get-closed-timestamp))
                 ;; Habit detection - only if the window-habit module is loaded
                 (is-window-habit (and (fboundp 'org-agenda-api--is-window-habit-p)
                                       (org-agenda-api--is-window-habit-p)))
                 (habit-summary (when (and is-window-habit
                                           (fboundp 'org-agenda-api--get-habit-summary))
                                  (org-agenda-api--get-habit-summary))))
            `(("todo" . ,todo)
              ("title" . ,title)
              ("tags" . ,(if tags (vconcat tags) nil))
              ("level" . ,level)
              ("scheduled" . ,(org-agenda-api--format-timestamp scheduled-time scheduled-has-time))
              ("deadline" . ,(org-agenda-api--format-timestamp deadline-time deadline-has-time))
              ("file" . ,filepath)
              ("pos" . ,pos)
              ("id" . ,org-id)
              ("olpath" . ,(if olpath (vconcat olpath) nil))
              ("priority" . ,priority)
              ("notifyBefore" . ,(when notify-before (vconcat notify-before)))
              ("category" . ,category)
              ("agendaLine" . ,(substring-no-properties agenda-line))
              ("properties" . ,all-properties)
              ("completedAt" . ,completed-at)
              ("isWindowHabit" . ,(if is-window-habit t :json-false))
              ,@(when habit-summary
                  `(("habitSummary" . ,habit-summary))))))))))

(defun org-agenda-api--run-agenda (span &optional start-date include-overdue include-completed)
  "Run org-agenda and return entries as a list of JSON-encodable alists.
SPAN should be `day' or `week'.
START-DATE is an optional date string in YYYY-MM-DD format.
INCLUDE-OVERDUE when non-nil includes overdue items from previous days.
INCLUDE-COMPLETED when non-nil includes items completed on the query date."
  (let* ((org-agenda-span span)
         (org-agenda-use-time-grid t)
         (org-agenda-start-on-weekday nil)
         (org-agenda-window-setup 'current-window)
         ;; Parse date string to calendar date format (month day year) if provided,
         ;; otherwise use calendar-current-date as the default (supports fake dates in tests)
         (parsed-date (if start-date
                          (let ((parts (split-string start-date "-")))
                            (when (= (length parts) 3)
                              (list (string-to-number (nth 1 parts))  ; month
                                    (string-to-number (nth 2 parts))  ; day
                                    (string-to-number (nth 0 parts))))) ; year
                        (calendar-current-date)))
         ;; Calculate absolute day number for the requested date
         ;; This is needed to properly override org-today for future date queries
         (absolute-day (when parsed-date
                         (calendar-absolute-from-gregorian parsed-date)))
         ;; Store original function definitions for restoration
         (orig-org-today (symbol-function 'org-today))
         (orig-calendar-current-date (symbol-function 'calendar-current-date))
         entries)
    ;; Debug logging
    (org-agenda-api--log 'debug "run-agenda: calendar-current-date=%S" (calendar-current-date))
    (org-agenda-api--log 'debug "run-agenda: org-today=%S" (org-today))
    (org-agenda-api--log 'debug "run-agenda: parsed-date=%S span=%S absolute-day=%S" parsed-date span absolute-day)
    (org-agenda-api--log 'debug "run-agenda: org-agenda-files=%S" org-agenda-files)
    (org-agenda-api--log 'debug "run-agenda: org-agenda-show-log=%S org-agenda-log-mode-items=%S"
                         org-agenda-show-log org-agenda-log-mode-items)
    ;; Store original values for restoration
    (let ((orig-org-agenda-show-log org-agenda-show-log)
          (orig-org-agenda-log-mode-items org-agenda-log-mode-items)
          (orig-org-agenda-start-with-log-mode org-agenda-start-with-log-mode))
      ;; Set log mode globally if include-completed is requested
      ;; (let-binding doesn't work reliably with org-agenda)
      (when include-completed
        (setq org-agenda-show-log t
              org-agenda-start-with-log-mode t
              org-agenda-log-mode-items '(closed state)))
      ;; Override org-today and calendar-current-date using fset for robust override
      ;; that works with byte-compiled code. cl-letf may not work reliably with
      ;; byte-compiled org-mode in production.
      (unwind-protect
          (progn
            ;; Override functions globally using fset
            (fset 'org-today (lambda () absolute-day))
            (fset 'calendar-current-date
                  (lambda (&optional offset)
                    (if offset
                        (calendar-gregorian-from-absolute (+ absolute-day offset))
                      parsed-date)))
            ;; Debug: verify overrides are in effect
            (org-agenda-api--log 'debug "run-agenda: AFTER OVERRIDE org-today=%S calendar-current-date=%S"
                                 (org-today) (calendar-current-date))
            (org-agenda-api--log 'debug "run-agenda: org-agenda-show-log=%S" org-agenda-show-log)
            ;; Prepare buffers INSIDE the override scope
            (org-agenda-prepare-buffers org-agenda-files)
            (save-window-excursion
              (org-agenda-list nil start-date (if (eq span 'day) 1 7))
            (with-current-buffer "*Org Agenda*"
              ;; Debug: log the agenda buffer contents
              (org-agenda-api--log 'debug "run-agenda: agenda buffer:\n%s" (buffer-string))
              (goto-char (point-min))
              ;; Skip the header lines (date header etc.)
              (while (not (eobp))
                (let* ((line (buffer-substring (line-beginning-position) (line-end-position)))
                       ;; Get org-hd-marker which points to the headline, not org-marker which
                       ;; points to the timestamp. We need the headline marker for org-at-heading-p.
                       (marker (get-text-property (line-beginning-position) 'org-hd-marker)))
                  ;; Debug logging for marker extraction
                  (when (> (length line) 0)
                    (org-agenda-api--log 'debug "run-agenda: line=%S marker=%S"
                                         (substring line 0 (min 50 (length line))) marker))
                  ;; Only include lines that have an org-hd-marker (actual entries)
                  (when marker
                    (org-agenda-api--log 'debug "run-agenda: Found marker, extracting data")
                    (let ((entry-data (org-agenda-api--extract-entry-data marker line)))
                      (org-agenda-api--log 'debug "run-agenda: entry-data=%S" entry-data)
                      (when entry-data
                        (push entry-data entries)))))
                (forward-line 1)))
            (kill-buffer "*Org Agenda*")))
        ;; Restore original functions
        (fset 'org-today orig-org-today)
        (fset 'calendar-current-date orig-calendar-current-date)
        ;; Restore log mode settings
        (setq org-agenda-show-log orig-org-agenda-show-log
              org-agenda-start-with-log-mode orig-org-agenda-start-with-log-mode
              org-agenda-log-mode-items orig-org-agenda-log-mode-items)))
    (org-agenda-api--log 'debug "run-agenda: Total entries found: %d" (length entries))
    (let ((all-entries (nreverse entries)))
      ;; Filter entries based on their scheduled date
      ;; When include-overdue is true: keep items scheduled for query date OR earlier (overdue)
      ;; When include-overdue is false: keep only items scheduled for query date exactly
      ;;
      ;; IMPORTANT: Use org-agenda-api--extract-date to compare only the date portion.
      ;; Without this, "2026-01-19T10:00:00" > "2026-01-19" due to string comparison of "T" vs end.
      (let ((filtered-entries
             (if include-overdue
                 ;; Include overdue: keep items where scheduled date <= start-date
                 (cl-remove-if-not
                  (lambda (entry)
                    (let ((scheduled-date (org-agenda-api--extract-date
                                           (cdr (assoc "scheduled" entry))))
                          (deadline-date (org-agenda-api--extract-date
                                          (cdr (assoc "deadline" entry))))
                          (completed-at-date (org-agenda-api--extract-date
                                              (cdr (assoc "completedAt" entry)))))
                      ;; Keep entries with:
                      ;; - scheduled date <= start-date (includes overdue)
                      ;; - deadline date <= start-date
                      ;; - completed on the query date
                      ;; - no scheduled/deadline ONLY when not in log mode
                      ;;   (When include-completed is true, log mode shows state change entries
                      ;;   that have no scheduled/deadline - these should only be kept if they
                      ;;   have a completedAt matching the query date)
                      (or (and (null scheduled-date) (null deadline-date) (not include-completed))
                          (and scheduled-date (not (string-greaterp scheduled-date start-date)))
                          (and deadline-date (not (string-greaterp deadline-date start-date)))
                          (and completed-at-date (string= completed-at-date start-date)))))
                  all-entries)
               ;; Default: only items scheduled for the exact query date
               (cl-remove-if-not
                (lambda (entry)
                  (let ((scheduled-date (org-agenda-api--extract-date
                                         (cdr (assoc "scheduled" entry))))
                        (deadline-date (org-agenda-api--extract-date
                                        (cdr (assoc "deadline" entry))))
                        (completed-at-date (org-agenda-api--extract-date
                                            (cdr (assoc "completedAt" entry)))))
                    ;; Keep entries that have either:
                    ;; - scheduled date matching start-date
                    ;; - deadline date matching start-date
                    ;; - completed at date matching start-date (log entries)
                    ;; - no scheduled/deadline (time grid items) ONLY when not in log mode
                    ;;   (When include-completed is true, log mode shows state change entries
                    ;;   that have no scheduled/deadline - these should only be kept if they
                    ;;   have a completedAt matching the query date)
                    (or (and (null scheduled-date) (null deadline-date) (not include-completed))
                        (and scheduled-date (string= scheduled-date start-date))
                        (and deadline-date (string= deadline-date start-date))
                        (and completed-at-date (string= completed-at-date start-date)))))
                all-entries))))
        ;; Deduplicate entries - when an item has both SCHEDULED and DEADLINE
        ;; on the same day, org-agenda shows it twice. Keep only unique entries
        ;; based on (file, pos).
        (org-agenda-api--deduplicate-entries filtered-entries)))))

(defun org-agenda-api--list-custom-views ()
  "Return a list of available custom agenda views.
Each view is an alist with \"key\" and \"name\" entries."
  (let ((views nil))
    (dolist (cmd org-agenda-custom-commands)
      (let ((key (car cmd))
            (rest (cdr cmd)))
        ;; Skip entries that are just category separators (string only)
        (when (and (stringp key)
                   (consp rest))
          (let ((name (if (stringp (car rest))
                          (car rest)
                        ;; No description, use key as name
                        key)))
            (push `(("key" . ,key)
                    ("name" . ,name))
                  views)))))
    (nreverse views)))

(defun org-agenda-api--run-custom-view (key)
  "Run the custom agenda view with KEY and return entries.
Returns a list of entry alists extracted from the agenda buffer."
  (org-agenda-api--log 'debug "run-custom-view: key=%s" key)
  (let ((entries nil)
        (org-agenda-window-setup 'current-window))
    (save-window-excursion
      ;; Run the custom agenda command
      (org-agenda nil key)
      (with-current-buffer "*Org Agenda*"
        (org-agenda-api--log 'debug "run-custom-view: agenda buffer:\n%s" (buffer-string))
        (goto-char (point-min))
        (while (not (eobp))
          (let* ((line (buffer-substring (line-beginning-position) (line-end-position)))
                 (marker (get-text-property (line-beginning-position) 'org-hd-marker)))
            (when marker
              (let ((entry-data (org-agenda-api--extract-entry-data marker line)))
                (when entry-data
                  (push entry-data entries)))))
          (forward-line 1)))
      (kill-buffer "*Org Agenda*"))
    (org-agenda-api--log 'debug "run-custom-view: Total entries found: %d" (length entries))
    ;; Deduplicate entries - when an item has both SCHEDULED and DEADLINE
    ;; on the same day, org-agenda shows it twice. Keep only unique entries
    ;; based on (file, pos).
    (org-agenda-api--deduplicate-entries (nreverse entries))))

(defun org-agenda-api--get-custom-view-name (key)
  "Get the name/description for the custom view with KEY."
  (let ((cmd (assoc key org-agenda-custom-commands)))
    (when cmd
      (let ((rest (cdr cmd)))
        (if (and (consp rest) (stringp (car rest)))
            (car rest)
          key)))))

(defun org-agenda-api--cleanup-emacs-state ()
  "Clean up Emacs state before capture to avoid minibuffer conflicts.
This resets any stuck state from previous failed operations."
  ;; Abort any active minibuffer
  (when (active-minibuffer-window)
    (org-agenda-api--log 'warn "Found active minibuffer, aborting it")
    (with-current-buffer (window-buffer (active-minibuffer-window))
      (abort-recursive-edit)))
  ;; Abort any in-progress capture
  (when (and (boundp 'org-capture-mode) org-capture-mode)
    (org-agenda-api--log 'warn "Found active capture, aborting it")
    (ignore-errors (org-capture-kill)))
  ;; Clear the mark to avoid issues
  (deactivate-mark)
  ;; Kill any capture buffers that might be lying around
  (dolist (buf (buffer-list))
    (when (string-match-p "\\*Capture\\*\\|CAPTURE-" (buffer-name buf))
      (org-agenda-api--log 'debug "Killing stale capture buffer: %s" (buffer-name buf))
      (kill-buffer buf))))

;;; Capture Template API Functions

(defun org-agenda-api--get-default-capture-target ()
  "Get the target file for the default capture template.
Returns the first file in `org-agenda-files', or signals an error if none exist."
  (let ((agenda-files (org-agenda-files)))
    (unless agenda-files
      (error "No agenda files configured - cannot capture"))
    (car agenda-files)))

(defun org-agenda-api--make-default-template ()
  "Create the default capture template entry.
Returns a template entry in the format (KEY . PLIST)."
  (let ((target-file (org-agenda-api--get-default-capture-target)))
    `("default" .
      (:name "Todo"
       :template ("d" "Todo" entry (file ,target-file)
                  "* TODO %^{Title}\n"
                  :immediate-finish t)
       :prompts (("Title" :type string :required t))))))

(defun org-agenda-api--get-template (key)
  "Get the API capture template with KEY.
If KEY is \"default\" and no user template exists with that key,
returns the built-in default template."
  (or (assoc key org-agenda-api-capture-templates)
      (when (string= key "default")
        (org-agenda-api--make-default-template))))

(defun org-agenda-api--template-to-json (template-entry)
  "Convert TEMPLATE-ENTRY to JSON-encodable alist."
  (let* ((key (car template-entry))
         (plist (cdr template-entry))
         (name (plist-get plist :name))
         (prompts (plist-get plist :prompts)))
    `(,key . (("name" . ,name)
              ("prompts" . ,(mapcar
                             (lambda (p)
                               (let ((pname (car p))
                                     (pplist (cdr p)))
                                 `(("name" . ,pname)
                                   ("type" . ,(symbol-name (plist-get pplist :type)))
                                   ("required" . ,(if (plist-get pplist :required) t :json-false)))))
                             prompts))))))

(defun org-agenda-api--get-all-templates-json ()
  "Get all registered templates as a JSON-encodable alist.
Include the built-in default template if no user template with
key \"default\" exists."
  (let ((user-templates (mapcar #'org-agenda-api--template-to-json
                                org-agenda-api-capture-templates)))
    ;; Add default template if not already defined by user
    (if (assoc "default" org-agenda-api-capture-templates)
        user-templates
      (cons (org-agenda-api--template-to-json (org-agenda-api--make-default-template))
            user-templates))))

(defvar org-agenda-api--current-capture-values nil
  "Dynamically bound alist of prompt values for current API capture.")

(defun org-agenda-api--validate-capture-values (template-entry values)
  "Validate that VALUES contains all required prompts for TEMPLATE-ENTRY.
Returns nil if valid, or an error message string if invalid."
  (let* ((plist (cdr template-entry))
         (prompts (plist-get plist :prompts))
         (missing nil))
    (dolist (prompt prompts)
      (let ((name (car prompt))
            (required (plist-get (cdr prompt) :required)))
        (when (and required (not (assoc name values)))
          (push name missing))))
    (when missing
      (format "Missing required fields: %s" (string-join missing ", ")))))

(defun org-agenda-api--format-tags (tags)
  "Format TAGS list or vector as org tag string like :tag1:tag2:."
  (let ((tag-list (cond
                   ((vectorp tags) (append tags nil))  ; Convert vector to list
                   ((listp tags) tags)
                   ((stringp tags) (split-string tags "," t "\\s-*"))
                   (t nil))))
    (if (and tag-list (> (length tag-list) 0))
        (concat ":" (mapconcat #'identity tag-list ":") ":")
      "")))

(defun org-agenda-api--format-date (date-string)
  "Convert DATE-STRING (ISO format) to org timestamp."
  (if date-string
      (let ((time (date-to-time (concat date-string " 00:00:00"))))
        (format-time-string (car org-time-stamp-formats) time))
    ""))

(defun org-agenda-api--format-inactive-timestamp ()
  "Return current time as inactive org timestamp."
  (format-time-string (car org-time-stamp-formats) (current-time)))

(defun org-agenda-api--build-entry-from-template (template-entry values)
  "Build an org entry string from TEMPLATE-ENTRY and VALUES.
This substitutes values into the template without interactive prompts."
  (let* ((plist (cdr template-entry))
         (prompts (plist-get plist :prompts))
         (capture-template (plist-get plist :template))
         (template-raw (nth 4 capture-template))
         ;; If template is a function, call it to get the actual string
         (template-string
          (cond
           ;; (function ...) form
           ((and (listp template-raw)
                 (eq (car template-raw) 'function))
            (funcall (cadr template-raw)))
           ;; Already a function
           ((functionp template-raw)
            (funcall template-raw))
           ;; Plain string
           (t template-raw)))
         (result template-string))
    ;; Replace %^{Name} with the value
    ;; Do patterns with suffixes FIRST, then without (otherwise suffix gets left behind)
    (dolist (prompt prompts)
      (let* ((name (car prompt))
             (ptype (plist-get (cdr prompt) :type))
             (value (cdr (assoc name values)))
             (formatted-value
              (pcase ptype
                ('string (or value ""))
                ('date (org-agenda-api--format-date value))
                ('tags (org-agenda-api--format-tags value))
                (_ (or value "")))))
        ;; First replace %^{Name}X patterns (like %^{When}t for date, %^{Tags}g for tags)
        (setq result (replace-regexp-in-string
                      (format "%%\\^{%s}[tTgGuU]" (regexp-quote name))
                      formatted-value
                      result t t))
        ;; Then replace plain %^{Name} pattern
        (setq result (replace-regexp-in-string
                      (format "%%\\^{%s}" (regexp-quote name))
                      formatted-value
                      result t t))))
    ;; Replace timestamp patterns - must be case-sensitive!
    ;; Without this, %T would match %t due to case-fold-search defaulting to t
    (let ((case-fold-search nil))
      ;; Replace %U with inactive timestamp
      (setq result (replace-regexp-in-string
                    "%U"
                    (format-time-string "[%Y-%m-%d %a %H:%M]" (current-time))
                    result t t))
      ;; Replace %u with inactive date (no time)
      (setq result (replace-regexp-in-string
                    "%u"
                    (format-time-string "[%Y-%m-%d %a]" (current-time))
                    result t t))
      ;; Replace %T with active timestamp
      (setq result (replace-regexp-in-string
                    "%T"
                    (format-time-string "<%Y-%m-%d %a %H:%M>" (current-time))
                    result t t))
      ;; Replace %t with active date
      (setq result (replace-regexp-in-string
                    "%t"
                    (format-time-string "<%Y-%m-%d %a>" (current-time))
                    result t t)))
    ;; Replace %? with Title value if present, otherwise remove it
    (let ((title-value (cdr (assoc "Title" values))))
      (setq result (replace-regexp-in-string
                    "%\\?"
                    (or title-value "")
                    result t t)))
    result))

(defun org-agenda-api--capture-with-template (template-key values)
  "Capture using TEMPLATE-KEY with VALUES for prompts.
VALUES is an alist of (PROMPT-NAME . VALUE) pairs.
In addition to template prompts, VALUES may contain universal org fields:
  - scheduled: ISO date string
  - deadline: ISO date string
  - priority: A, B, or C
  - tags: list of tag strings
  - todo: TODO state keyword
These are applied after the entry is created.
Returns an alist with status information."
  (let ((template-entry (org-agenda-api--get-template template-key)))
    (unless template-entry
      (error "Unknown template: %s" template-key))
    (let ((validation-error (org-agenda-api--validate-capture-values template-entry values)))
      (when validation-error
        (error "%s" validation-error)))
    (let* ((plist (cdr template-entry))
           (capture-template (plist-get plist :template))
           (target-file (let ((target (nth 3 capture-template)))
                          (if (and (listp target) (eq (car target) 'file))
                              (cadr target)
                            (org-agenda-api--get-default-capture-target))))
           (entry-text (org-agenda-api--build-entry-from-template template-entry values))
           ;; Extract universal fields from values
           (scheduled (cdr (assoc "scheduled" values)))
           (deadline (cdr (assoc "deadline" values)))
           (priority (cdr (assoc "priority" values)))
           (tags (cdr (assoc "tags" values)))
           (todo-state (cdr (assoc "todo" values)))
           (entry-pos nil))
      ;; Append entry to target file
      (with-current-buffer (find-file-noselect target-file)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (setq entry-pos (point))
        (insert entry-text)
        (unless (string-suffix-p "\n" entry-text) (insert "\n"))
        ;; Apply universal fields to the newly created entry
        (save-excursion
          (goto-char entry-pos)
          (when (org-at-heading-p)
            ;; Apply TODO state if specified and different from template default
            (when (and todo-state
                       (not (string-empty-p todo-state))
                       (not (string= todo-state "TODO")))
              (org-todo todo-state))
            ;; Apply priority
            (when (and priority (not (string-empty-p priority)))
              (let ((priority-char (string-to-char (upcase priority))))
                (when (memq priority-char '(?A ?B ?C))
                  (org-priority priority-char))))
            ;; Apply scheduled - use org timestamp string to preserve time
            (when (and scheduled (not (string-empty-p scheduled)))
              (let* ((has-time (org-agenda-api--datetime-has-time-p scheduled))
                     (time (org-agenda-api--parse-datetime scheduled))
                     (org-ts (when time (org-agenda-api--format-org-timestamp time has-time))))
                (when org-ts
                  (org-schedule nil org-ts))))
            ;; Apply deadline - use org timestamp string to preserve time
            (when (and deadline (not (string-empty-p deadline)))
              (let* ((has-time (org-agenda-api--datetime-has-time-p deadline))
                     (time (org-agenda-api--parse-datetime deadline))
                     (org-ts (when time (org-agenda-api--format-org-timestamp time has-time))))
                (when org-ts
                  (org-deadline nil org-ts))))
            ;; Apply tags
            (when (and tags (> (length tags) 0))
              (let ((tag-list (if (vectorp tags) (append tags nil) tags)))
                (org-set-tags tag-list)))))
        (save-buffer))
      (org-agenda-api--invalidate-cache)
      `(("status" . "created")
        ("template" . ,template-key)))))

;;; HTTP Endpoints

(defun org-agenda-api--get-default-notify-before ()
  "Get default notification times from org-wild-notifier-alert-time if available.
Returns a list of integers (minutes before event)."
  (let ((alert-time (and (boundp 'org-wild-notifier-alert-time)
                         org-wild-notifier-alert-time)))
    (cond
     ((null alert-time) '(10))  ; Default to 10 minutes if not configured
     ((listp alert-time) alert-time)
     ((integerp alert-time) (list alert-time))
     (t '(10)))))

(defservlet get-all-todos application/json (_path query)
  "Endpoint: Return all TODO items from agenda files as JSON.
Response is wrapped with notification defaults.
Accepts optional query param 'refresh' (true/1) to git pull repos first."
  (let* ((refresh-param (cadr (assoc "refresh" query)))
         (git-results (when (member refresh-param '("true" "1"))
                        (org-agenda-api--git-refresh-all)))
         (todos (org-agenda-api--get-agenda-todos))
         (defaults `(("notifyBefore" . ,(vconcat (org-agenda-api--get-default-notify-before)))))
         (response `(("defaults" . ,defaults)
                     ("todos" . ,(vconcat todos)))))
    (when git-results
      (push `("gitRefresh" . ,(vconcat git-results)) response))
    (insert (json-encode response)))
  (org-agenda-api--track-request))

(defservlet get-todays-agenda application/json ()
  "Endpoint: Return today's scheduled and deadlined items as JSON."
  (insert (json-encode
           (mapcar #'org-agenda-api--item-to-json
                   (org-agenda-api--get-today-agenda))))
  (org-agenda-api--track-request))

(defservlet agenda application/json (_path query)
  "Endpoint: Return org-agenda entries as JSON.
Accepts optional query params:
  - 'span' (day or week, defaults to day)
  - 'date' (YYYY-MM-DD format, defaults to today)
  - 'include_overdue' (true/1) to include overdue items from previous days (default: false)
  - 'include_completed' (true/1) to include items completed on this date (default: false)
  - 'refresh' (true/1) to git pull repos first."
  (let* ((span-param (cadr (assoc "span" query)))
         (date-param (cadr (assoc "date" query)))
         (include-overdue-param (cadr (assoc "include_overdue" query)))
         (include-completed-param (cadr (assoc "include_completed" query)))
         (refresh-param (cadr (assoc "refresh" query)))
         (git-results (when (member refresh-param '("true" "1"))
                        (org-agenda-api--git-refresh-all)))
         (span (if (string= span-param "week") 'week 'day))
         (include-overdue (member include-overdue-param '("true" "1")))
         (include-completed (member include-completed-param '("true" "1")))
         ;; Use requested date or default to today (using calendar-current-date for testability)
         (today (calendar-current-date))
         (today-str (format "%04d-%02d-%02d" (nth 2 today) (nth 0 today) (nth 1 today)))
         (effective-date (or date-param today-str))
         (entries (org-agenda-api--run-agenda span effective-date include-overdue include-completed))
         (response `(("span" . ,(symbol-name span))
                     ("date" . ,effective-date)
                     ("entries" . ,(vconcat entries)))))
    (when git-results
      (push `("gitRefresh" . ,(vconcat git-results)) response))
    (insert (json-encode response)))
  (org-agenda-api--track-request))

(defservlet capture-templates application/json ()
  "Endpoint: Return registered capture templates and their prompts."
  (condition-case err
      (let ((templates-data (org-agenda-api--get-all-templates-json)))
        (message "[org-agenda-api] /capture-templates: returning %d templates"
                 (length templates-data))
        (insert (json-encode templates-data)))
    (error
     (message "[org-agenda-api] /capture-templates ERROR: %S" err)
     (message "[org-agenda-api] org-agenda-api-capture-templates: %S"
              org-agenda-api-capture-templates)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(format "Server error: %S" err)))))))
  (org-agenda-api--track-request))

(defservlet capture application/json (_path _query headers)
  "Endpoint: Capture using a registered template with provided values."
  (condition-case err
      (let* ((content-header (cadr (assoc "Content" headers)))
             (json-data (json-parse-string content-header))
             (template-key (gethash "template" json-data))
             (values-hash (gethash "values" json-data))
             ;; Convert hash-table to alist
             (values (let (alist)
                       (maphash (lambda (k v) (push (cons k v) alist)) values-hash)
                       alist))
             (result (org-agenda-api--capture-with-template template-key values)))
        (insert (json-encode result)))
    (error
     ;; Return error as JSON with appropriate status
     ;; Note: simple-httpd doesn't have great error handling, so we return 200 with error in body
     ;; A better approach would need custom error handling
     (org-agenda-api--log-error-with-backtrace "/capture" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defun org-agenda-api--check-capture-ready ()
  "Check if capture system is ready (not stuck in minibuffer etc.).
Returns nil if healthy, or an error message string if unhealthy."
  (condition-case err
      (progn
        ;; Check for stuck minibuffer
        (when (active-minibuffer-window)
          (throw 'unhealthy "minibuffer is active"))
        ;; Check for stuck capture mode
        (when (and (boundp 'org-capture-mode) org-capture-mode)
          (throw 'unhealthy "capture mode is active"))
        ;; All checks passed
        nil)
    (error (error-message-string err))))

(defservlet health application/json ()
  "Endpoint: Health check for monitoring systems (nginx, supervisord, etc.).
Returns basic status information and capture readiness check."
  (let* ((uptime (when org-agenda-api--start-time
                   (float-time (time-subtract (current-time) org-agenda-api--start-time))))
         (capture-check (catch 'unhealthy (org-agenda-api--check-capture-ready)))
         (healthy (null capture-check))
         (response `(("status" . ,(if healthy "ok" "unhealthy"))
                     ("uptime" . ,uptime)
                     ("requests" . ,org-agenda-api--request-count))))
    (when capture-check
      (push `("captureStatus" . ,capture-check) response)
      (org-agenda-api--log 'warn "Health check failed: %s" capture-check))
    (insert (json-encode response))
    ;; Return 503 if unhealthy so supervisord/nginx can detect it
    (unless healthy
      (httpd-error httpd-current-proc 503))))

(defservlet version application/json ()
  "Endpoint: Return version information including semantic version and git commit hash.
The git commit is read from the ORG_AGENDA_API_GIT_COMMIT environment variable,
which is set at build time by the Nix flake."
  (let* ((git-commit (or (getenv "ORG_AGENDA_API_GIT_COMMIT") "unknown"))
         (response `(("version" . ,org-agenda-api-version)
                     ("gitCommit" . ,git-commit))))
    (insert (json-encode response))))

(defservlet debug-config application/json ()
  "Endpoint: Return current org configuration for debugging."
  (let ((response `(("org-log-into-drawer" . ,org-log-into-drawer)
                    ("org-log-done" . ,org-log-done)
                    ("org-log-repeat" . ,org-log-repeat)
                    ("org-log-reschedule" . ,org-log-reschedule)
                    ("org-log-redeadline" . ,org-log-redeadline)
                    ("org-todo-keywords" . ,(format "%S" org-todo-keywords))
                    ("custom-elisp-file" . ,(getenv "ORG_API_CUSTOM_ELISP")))))
    (insert (json-encode response))))

(defun org-agenda-api--get-todo-states ()
  "Get all configured TODO states from `org-todo-keywords'.
Return alist with \"active\" (not-done) and \"done\" states.
Handles both list and vector formats in `org-todo-keywords'."
  (let ((active-states nil)
        (done-states nil))
    (dolist (keyword-set org-todo-keywords)
      (let ((in-done-section nil)
            ;; Convert to list if it's a vector, skip first element (sequence/type)
            (keywords (cdr (if (vectorp keyword-set)
                               (append keyword-set nil)
                             keyword-set))))
        (dolist (keyword keywords)
          (cond
           ((string= keyword "|")
            (setq in-done-section t))
           (t
            ;; Handle keywords with shortcuts like "TODO(t)"
            (let ((clean-keyword (if (string-match-p "(.*)$" keyword)
                                     (replace-regexp-in-string "(.*)$" "" keyword)
                                   keyword)))
              (if in-done-section
                  (push clean-keyword done-states)
                (push clean-keyword active-states))))))))
    `(("active" . ,(vconcat (nreverse active-states)))
      ("done" . ,(vconcat (nreverse done-states))))))

(defun org-agenda-api--get-filter-options ()
  "Get all available filter options from agenda files.
Returns an alist with todoStates, priorities, tags, and categories."
  (let ((todo-states (org-agenda-api--get-todo-states))
        (priorities '())
        (tags '())
        (categories '()))
    ;; Get priority range
    (let ((highest (or org-priority-highest ?A))
          (lowest (or org-priority-lowest ?C)))
      (setq priorities
            (mapcar #'char-to-string
                    (number-sequence highest lowest))))
    ;; Collect tags and categories from all agenda files
    (dolist (file (mapcar #'expand-file-name org-agenda-files))
      (condition-case nil
          (when (file-readable-p file)
            (with-current-buffer (find-file-noselect file)
              ;; Get file-level category
              (save-excursion
                (goto-char (point-min))
                (when (re-search-forward "^#\\+CATEGORY:[ \t]+\\(.+\\)$" nil t)
                  (let ((cat (string-trim (match-string 1))))
                    (unless (member cat categories)
                      (push cat categories)))))
              ;; Get tags from buffer
              (let ((buffer-tags (org-get-buffer-tags)))
                (dolist (tag-pair buffer-tags)
                  (let ((tag (car tag-pair)))
                    (unless (member tag tags)
                      (push tag tags)))))
              ;; Get categories from headings
              (org-map-entries
               (lambda ()
                 (let ((cat (org-get-category)))
                   (when (and cat (not (member cat categories)))
                     (push cat categories))))
               nil 'file)))
        (error nil)))  ; Silently skip files that cause errors
    `(("todoStates" . ,(vconcat (cdr (assoc "active" todo-states))
                                (cdr (assoc "done" todo-states))))
      ("priorities" . ,(vconcat priorities))
      ("tags" . ,(vconcat (sort tags #'string<)))
      ("categories" . ,(vconcat (sort categories #'string<))))))

(defservlet todo-states application/json ()
  "Endpoint: Return configured TODO states.
Returns active (not-done) states and done states separately."
  (insert (json-encode (org-agenda-api--get-todo-states)))
  (org-agenda-api--track-request))

(defservlet filter-options application/json ()
  "Endpoint: Return all available filter options for the UI.
Returns todoStates, priorities, tags, and categories."
  (condition-case err
      (progn
        (message "[org-agenda-api] /filter-options: fetching options...")
        (let ((result (org-agenda-api--get-filter-options)))
          (message "[org-agenda-api] /filter-options: got %d todo states, %d priorities, %d tags, %d categories"
                   (length (cdr (assoc "todoStates" result)))
                   (length (cdr (assoc "priorities" result)))
                   (length (cdr (assoc "tags" result)))
                   (length (cdr (assoc "categories" result))))
          (insert (json-encode result))))
    (error
     (message "[org-agenda-api] /filter-options ERROR: %S" err)
     (httpd-error t 500 (format "Error: %S" err))))
  (org-agenda-api--track-request))

(defservlet agenda-files application/json ()
  "Endpoint: Return the list of org-agenda-files as JSON."
  (let* ((files (mapcar #'expand-file-name org-agenda-files))
         (file-info (mapcar (lambda (f)
                              `(("path" . ,f)
                                ("exists" . ,(if (file-exists-p f) t :json-false))
                                ("readable" . ,(if (file-readable-p f) t :json-false))))
                            files))
         (response `(("count" . ,(length files))
                     ("files" . ,(vconcat file-info)))))
    (insert (json-encode response)))
  (org-agenda-api--track-request))

(defservlet custom-views application/json ()
  "Endpoint: Return list of available custom agenda views."
  (condition-case err
      (let* ((views (org-agenda-api--list-custom-views))
             (response `(("views" . ,(vconcat views)))))
        (message "[org-agenda-api] /custom-views: returning %d views"
                 (length views))
        (insert (json-encode response)))
    (error
     (message "[org-agenda-api] /custom-views ERROR: %S" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(format "Server error: %S" err)))))))
  (org-agenda-api--track-request))

(defservlet metadata application/json ()
  "Endpoint: Return all app metadata in a single request.
Returns templates, filterOptions, todoStates, customViews, and any errors."
  (let ((result '())
        (errors '()))
    ;; Collect templates
    (condition-case err
        (push `("templates" . ,(org-agenda-api--get-all-templates-json)) result)
      (error
       (push (format "templates: %s" (error-message-string err)) errors)
       (push '("templates" . nil) result)))
    ;; Collect filter options
    (condition-case err
        (push `("filterOptions" . ,(org-agenda-api--get-filter-options)) result)
      (error
       (push (format "filterOptions: %s" (error-message-string err)) errors)
       (push '("filterOptions" . nil) result)))
    ;; Collect todo states
    (condition-case err
        (push `("todoStates" . ,(org-agenda-api--get-todo-states)) result)
      (error
       (push (format "todoStates: %s" (error-message-string err)) errors)
       (push '("todoStates" . nil) result)))
    ;; Collect custom views
    (condition-case err
        (let ((views (org-agenda-api--list-custom-views)))
          (push `("customViews" . (("views" . ,(vconcat views)))) result))
      (error
       (push (format "customViews: %s" (error-message-string err)) errors)
       (push '("customViews" . nil) result)))
    ;; Add errors array
    (push `("errors" . ,(vconcat (nreverse errors))) result)
    (insert (json-encode (nreverse result))))
  (org-agenda-api--track-request))

(defservlet custom-view application/json (_path query)
  "Endpoint: Run a custom agenda view and return entries as JSON.
Accepts query params:
  - 'key' (required): The custom agenda command key
  - 'refresh' (optional): If 'true' or '1', git pull repos first."
  (let* ((key (cadr (assoc "key" query)))
         (refresh-param (cadr (assoc "refresh" query)))
         (git-results (when (member refresh-param '("true" "1"))
                        (org-agenda-api--git-refresh-all))))
    (if (or (null key) (string= key ""))
        (insert (json-encode `(("status" . "error")
                               ("message" . "Missing required 'key' parameter"))))
      (let* ((name (org-agenda-api--get-custom-view-name key))
             (entries (org-agenda-api--run-custom-view key))
             (response `(("key" . ,key)
                         ("name" . ,name)
                         ("entries" . ,(vconcat entries)))))
        (when git-results
          (push `("gitRefresh" . ,(vconcat git-results)) response))
        (insert (json-encode response)))))
  (org-agenda-api--track-request))

(defservlet restart application/json ()
  "Endpoint: Restart Emacs.
Exits gracefully, allowing supervisord to restart the process."
  (insert (json-encode `(("status" . "restarting"))))
  ;; Use run-at-time to allow the response to be sent before exiting
  (run-at-time 0.1 nil #'kill-emacs 0))

(defun org-agenda-api--find-todo-by-id (id)
  "Find a TODO entry by its org ID.
Returns (file . pos) cons or nil if not found."
  (when id
    (let ((loc (org-id-find id)))
      (when loc
        (cons (car loc) (cdr loc))))))

(defun org-agenda-api--find-todo-by-file-pos-title (file pos title)
  "Find a TODO entry by FILE, POS, and TITLE.
Verifies the title matches at the given position.
Returns (file . pos) cons or nil if not found."
  (when (and file pos (file-exists-p file))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char pos)
        (when (org-at-heading-p)
          (let ((heading (org-get-heading t t t t)))
            (when (or (not title) (string= heading title))
              (cons file pos))))))))

(defun org-agenda-api--find-todo-by-file-title (file title)
  "Find a TODO entry by FILE and TITLE only.
Searches the file for a heading matching TITLE.
Returns (file . pos) cons or nil if not found."
  (when (and file title (file-exists-p file))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-min))
        (let ((found nil))
          (while (and (not found) (re-search-forward org-heading-regexp nil t))
            (when (org-at-heading-p)
              (let ((heading (org-get-heading t t t t)))
                (when (string= heading title)
                  (setq found (cons file (line-beginning-position)))))))
          found)))))

(defun org-agenda-api--find-todo-by-title (title)
  "Find a TODO entry by TITLE across all agenda files.
Searches all org-agenda-files for a heading matching TITLE.
Returns (file . pos) cons or nil if not found."
  (when title
    (let ((found nil))
      (dolist (file org-agenda-files)
        (when (and (not found) (file-exists-p file))
          (setq found (org-agenda-api--find-todo-by-file-title file title))))
      found)))

(defun org-agenda-api--complete-todo-at (file pos &optional new-state)
  "Mark the TODO at FILE and POS as complete.
NEW-STATE defaults to DONE if not specified.
Returns alist with status and details."
  (let ((new-state (or new-state "DONE")))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char pos)
        (if (org-at-heading-p)
            (let ((old-state (org-get-todo-state))
                  (title (org-get-heading t t t t)))
              (org-todo new-state)
              ;; Run post-command-hook to trigger org-mode's state change logging
              ;; (LOGBOOK entries). In non-interactive contexts, org-add-log-note
              ;; is added to post-command-hook but never runs without this.
              (run-hooks 'post-command-hook)
              (save-buffer)
              (org-agenda-api--invalidate-cache)
              ;; Check if this is a window-habit and get summary if so
              (let* ((is-habit (and (fboundp 'org-agenda-api--is-window-habit-p)
                                    (org-agenda-api--is-window-habit-p)))
                     (habit-summary (when (and is-habit
                                               (fboundp 'org-agenda-api--get-habit-summary))
                                      (org-agenda-api--get-habit-summary))))
                `(("status" . "completed")
                  ("title" . ,title)
                  ("oldState" . ,old-state)
                  ("newState" . ,new-state)
                  ,@(when habit-summary
                      `(("habitSummary" . ,habit-summary))))))
          `(("status" . "error")
            ("message" . "No heading found at position")))))))

(defun org-agenda-api--datetime-has-time-p (datetime-string)
  "Return non-nil if DATETIME-STRING includes a time component."
  (and datetime-string
       (not (string-empty-p datetime-string))
       (string-match-p ":" datetime-string)))

(defun org-agenda-api--parse-datetime (datetime-string)
  "Parse DATETIME-STRING into an Emacs time value.
Accepts ISO format: YYYY-MM-DD or YYYY-MM-DD HH:MM or YYYY-MM-DDTHH:MM:SS."
  (when (and datetime-string (not (string-empty-p datetime-string)))
    (let* ((normalized (replace-regexp-in-string "T" " " datetime-string))
           (colon-count (cl-count ?: normalized)))
      (condition-case nil
          (cond
           ;; No colons: date only (YYYY-MM-DD)
           ((= colon-count 0)
            (date-to-time (concat normalized " 00:00:00")))
           ;; One colon: time without seconds (YYYY-MM-DD HH:MM)
           ((= colon-count 1)
            (date-to-time (concat normalized ":00")))
           ;; Two colons: full datetime with seconds (YYYY-MM-DD HH:MM:SS)
           (t
            (date-to-time normalized)))
        (error nil)))))

(defun org-agenda-api--format-org-timestamp (time has-time)
  "Format TIME as an org timestamp string.
If HAS-TIME is non-nil, include the time component."
  (if has-time
      (format-time-string "<%Y-%m-%d %a %H:%M>" time)
    (format-time-string "<%Y-%m-%d %a>" time)))

(defun org-agenda-api--update-todo-at (file pos updates)
  "Update the TODO at FILE and POS with UPDATES alist.
UPDATES can contain: new_title, scheduled, deadline, priority, tags, properties.
Returns alist with status, details, and new position."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char pos)
      (if (org-at-heading-p)
          (let ((title (org-get-heading t t t t))
                (applied-updates nil)
                (new-pos nil))
            ;; Handle title update (must be done first as it changes heading structure)
            (when (assoc "new_title" updates)
              (let ((new-title-value (cdr (assoc "new_title" updates))))
                (when (and new-title-value (not (string-empty-p new-title-value)))
                  (org-edit-headline new-title-value)
                  (setq title new-title-value)  ; Update title for response
                  (push `("new_title" . ,new-title-value) applied-updates))))
            ;; Handle scheduled
            (when (assoc "scheduled" updates)
              (let ((scheduled-value (cdr (assoc "scheduled" updates))))
                (if (or (null scheduled-value) (string-empty-p scheduled-value))
                    ;; Clear scheduled
                    (progn
                      (org-schedule '(4))  ; Universal arg removes scheduling
                      (push '("scheduled" . nil) applied-updates))
                  ;; Set scheduled - use org timestamp string to preserve time
                  (let* ((has-time (org-agenda-api--datetime-has-time-p scheduled-value))
                         (time (org-agenda-api--parse-datetime scheduled-value))
                         (org-ts (when time (org-agenda-api--format-org-timestamp time has-time))))
                    (when org-ts
                      (org-schedule nil org-ts)
                      (push `("scheduled" . ,scheduled-value) applied-updates))))))
            ;; Handle deadline
            (when (assoc "deadline" updates)
              (let ((deadline-value (cdr (assoc "deadline" updates))))
                (if (or (null deadline-value) (string-empty-p deadline-value))
                    ;; Clear deadline
                    (progn
                      (org-deadline '(4))  ; Universal arg removes deadline
                      (push '("deadline" . nil) applied-updates))
                  ;; Set deadline - use org timestamp string to preserve time
                  (let* ((has-time (org-agenda-api--datetime-has-time-p deadline-value))
                         (time (org-agenda-api--parse-datetime deadline-value))
                         (org-ts (when time (org-agenda-api--format-org-timestamp time has-time))))
                    (when org-ts
                      (org-deadline nil org-ts)
                      (push `("deadline" . ,deadline-value) applied-updates))))))
            ;; Handle priority
            (when (assoc "priority" updates)
              (let ((priority-value (cdr (assoc "priority" updates))))
                (if (or (null priority-value) (string-empty-p priority-value))
                    ;; Clear priority - ignore error if no priority cookie exists
                    (progn
                      (condition-case nil
                          (org-priority ?\s)  ; Space removes priority
                        (error nil))  ; Ignore "No priority cookie found" error
                      (push '("priority" . nil) applied-updates))
                  ;; Set priority (A, B, or C)
                  (let ((priority-char (string-to-char (upcase priority-value))))
                    (when (memq priority-char '(?A ?B ?C))
                      (org-priority priority-char)
                      (push `("priority" . ,priority-value) applied-updates))))))
            ;; Handle tags
            (when (assoc "tags" updates)
              (let ((tags-value (cdr (assoc "tags" updates))))
                ;; Only process if not null/json-null (null means no change)
                (unless (or (eq tags-value :json-null)
                            (and (not (vectorp tags-value)) (null tags-value)))
                  ;; Convert vector to list if needed, then set tags
                  (let ((tag-list (if (vectorp tags-value)
                                      (append tags-value nil)
                                    tags-value)))
                    (org-set-tags tag-list)
                    (push `("tags" . ,(vconcat tag-list)) applied-updates)))))
            ;; Handle arbitrary properties
            (when (assoc "properties" updates)
              (let ((properties-value (cdr (assoc "properties" updates)))
                    (applied-props nil))
                ;; properties-value should be an alist of (KEY . VALUE) pairs
                (when (and properties-value
                           (not (eq properties-value :json-null)))
                  (dolist (prop properties-value)
                    (let ((prop-name (car prop))
                          (prop-value (cdr prop)))
                      ;; Convert property name to uppercase for org-mode convention
                      (let ((prop-name-upper (upcase prop-name)))
                        (if (or (null prop-value) (string-empty-p prop-value))
                            ;; Remove property if value is empty
                            (progn
                              (org-entry-delete (point) prop-name-upper)
                              (push (cons prop-name-upper nil) applied-props))
                          ;; Set property
                          (org-entry-put (point) prop-name-upper prop-value)
                          (push (cons prop-name-upper prop-value) applied-props)))))
                  (when applied-props
                    (push `("properties" . ,applied-props) applied-updates)))))
            ;; Run post-command-hook to trigger any deferred logging (e.g., reschedule/redeadline)
            (run-hooks 'post-command-hook)
            (save-buffer)
            (org-agenda-api--invalidate-cache)
            ;; Get new position - go back to beginning of heading line
            (org-back-to-heading t)
            (setq new-pos (point))
            `(("status" . "updated")
              ("title" . ,title)
              ("file" . ,file)
              ("pos" . ,new-pos)
              ("updates" . ,applied-updates)))
        `(("status" . "error")
          ("message" . "No heading found at position"))))))

(defservlet update application/json (_path _query headers)
  "Endpoint: Update a TODO's title, scheduled date, deadline, priority, tags, or properties.
Accepts JSON body with:
  - id: org-id of the todo (preferred)
  - file: file path (fallback)
  - pos: position in file (fallback)
  - title: heading title (can match by title alone or with file)
  - new_title: new title to set for the heading
  - scheduled: ISO date/datetime string or null to clear
  - deadline: ISO date/datetime string or null to clear
  - priority: A, B, C, or null to clear
  - tags: array of tag strings to set, or empty array to clear
  - properties: object of property name/value pairs to set/update
Returns updated todo with new file and pos for cache update."
  (condition-case err
      (catch 'done
        (let* ((content-header (cadr (assoc "Content" headers)))
               (json-data (json-parse-string content-header))
               (id (gethash "id" json-data))
               (file (gethash "file" json-data))
               (pos (gethash "pos" json-data))
               (title (gethash "title" json-data))
               (new-title (gethash "new_title" json-data))
               (scheduled (gethash "scheduled" json-data))
               (deadline (gethash "deadline" json-data))
               (priority (gethash "priority" json-data))
               (tags (gethash "tags" json-data))
               (properties (gethash "properties" json-data))
               (location nil)
               (updates nil))
          ;; Log incoming request for debugging
        (message "[/update] Request: id=%s file=%s pos=%s title=%s new_title=%s scheduled=%s deadline=%s priority=%s"
                 id file pos title new-title scheduled deadline priority)
        ;; Check for unrecognized fields
        (let ((allowed-fields '("id" "file" "pos" "title" "new_title" "scheduled" "deadline" "priority" "tags" "properties"))
              (unrecognized nil))
          (maphash (lambda (key _value)
                     (unless (member key allowed-fields)
                       (push key unrecognized)))
                   json-data)
          (when unrecognized
            (message "[/update] ERROR: Unrecognized fields: %s" unrecognized)
            (insert (json-encode `(("status" . "error")
                                   ("message" . ,(format "Unrecognized fields: %s. Did you mean 'scheduled' instead of 'schedule'?"
                                                         (string-join unrecognized ", "))))))
            (throw 'done nil)))
        ;; Build updates alist (include keys even if value is nil, to signal clearing)
        ;; Use :not-found sentinel to properly detect if key exists in JSON
        (unless (eq (gethash "new_title" json-data :not-found) :not-found)
          (push (cons "new_title" (if (eq new-title :null) nil new-title)) updates))
        (unless (eq (gethash "scheduled" json-data :not-found) :not-found)
          (push (cons "scheduled" (if (eq scheduled :null) nil scheduled)) updates))
        (unless (eq (gethash "deadline" json-data :not-found) :not-found)
          (push (cons "deadline" (if (eq deadline :null) nil deadline)) updates))
        (unless (eq (gethash "priority" json-data :not-found) :not-found)
          (push (cons "priority" (if (eq priority :null) nil priority)) updates))
        (unless (eq (gethash "tags" json-data :not-found) :not-found)
          (push (cons "tags" (if (eq tags :null) nil tags)) updates))
        ;; Handle properties - convert hash-table to alist
        (unless (eq (gethash "properties" json-data :not-found) :not-found)
          (let ((props-alist nil))
            (when (and properties (hash-table-p properties))
              (maphash (lambda (k v)
                         (push (cons k (if (eq v :null) nil v)) props-alist))
                       properties))
            (push (cons "properties" props-alist) updates)))
        (message "[/update] Updates to apply: %S" updates)
        ;; Try to find by ID first
        (setq location (org-agenda-api--find-todo-by-id id))
        (when location (message "[/update] Found by ID"))
        ;; Fall back to file+pos+title
        (unless location
          (setq location (org-agenda-api--find-todo-by-file-pos-title file pos title))
          (when location (message "[/update] Found by file+pos+title")))
        ;; Fall back to file+title (handles position drift)
        (unless location
          (setq location (org-agenda-api--find-todo-by-file-title file title))
          (when location (message "[/update] Found by file+title")))
        ;; Fall back to title only across all agenda files
        (unless location
          (setq location (org-agenda-api--find-todo-by-title title))
          (when location (message "[/update] Found by title only")))
        (message "[/update] Location: %S" location)
        (if location
            (let ((result (org-agenda-api--update-todo-at
                           (car location) (cdr location) updates)))
              (insert (json-encode result)))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Todo not found")))))))
    (error
     (org-agenda-api--log-error-with-backtrace "/update" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defservlet complete application/json (_path _query headers)
  "Endpoint: Mark a TODO as complete.
Accepts JSON body with:
  - id: org-id of the todo (preferred)
  - file: file path (fallback)
  - pos: position in file (fallback)
  - title: heading title (for verification)
  - state: new state (optional, defaults to DONE)"
  (condition-case err
      (let* ((content-header (cadr (assoc "Content" headers)))
             (json-data (json-parse-string content-header))
             (id (gethash "id" json-data))
             (file (gethash "file" json-data))
             (pos (gethash "pos" json-data))
             (title (gethash "title" json-data))
             (new-state (gethash "state" json-data))
             (location nil))
        ;; Try to find by ID first
        (setq location (org-agenda-api--find-todo-by-id id))
        ;; Fall back to file+pos+title
        (unless location
          (setq location (org-agenda-api--find-todo-by-file-pos-title file pos title)))
        ;; Fall back to file+title (handles position drift)
        (unless location
          (setq location (org-agenda-api--find-todo-by-file-title file title)))
        ;; Fall back to title only across all agenda files
        (unless location
          (setq location (org-agenda-api--find-todo-by-title title)))
        (if location
            (let ((result (org-agenda-api--complete-todo-at
                           (car location) (cdr location) new-state)))
              (insert (json-encode result)))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Todo not found"))))))
    (error
     (org-agenda-api--log-error-with-backtrace "/complete" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defun org-agenda-api--delete-item (id file position include-children)
  "Delete an org item identified by ID or FILE+POSITION.
If INCLUDE-CHILDREN is nil and item has children, return error.
Returns alist with deletion result."
  ;; Locate the item
  (let* ((location (cond
                    (id (org-id-find id))
                    ((and file position) (cons file position))
                    (t (error "Must provide either 'id' or 'file' and 'position'"))))
         (target-file (car location))
         (target-pos (cdr location)))

    (unless location
      (error "Item not found"))

    (unless (file-exists-p target-file)
      (error "File not found: %s" target-file))

    ;; Verify file is in agenda files (security check)
    (unless (member target-file (org-agenda-files))
      (error "File is not an agenda file: %s" target-file))

    ;; Open file and navigate to position
    (with-current-buffer (find-file-noselect target-file)
      (widen)
      (goto-char target-pos)

      ;; Verify we're at a heading
      (unless (org-at-heading-p)
        (error "Position is not at a headline"))

      ;; Get title before deletion
      (let ((title (org-get-heading t t t t))
            (children-count 0))

        ;; Count direct children
        (save-excursion
          (when (org-goto-first-child)
            (setq children-count 1)
            (while (org-get-next-sibling)
              (setq children-count (1+ children-count)))))

        ;; Check if we need confirmation for children
        (when (and (> children-count 0) (not include-children))
          (error "Item has %d children. Set include_children=true to delete subtree."
                 children-count))

        ;; Delete the subtree
        (org-cut-subtree)
        (save-buffer)

        ;; Invalidate cache
        (org-agenda-api--invalidate-cache)

        ;; Return result
        (if (> children-count 0)
            `(("deleted" . t)
              ("title" . ,title)
              ("children_deleted" . ,children-count))
          `(("deleted" . t)
            ("title" . ,title)))))))

(defservlet delete application/json (_path _query headers)
  "Endpoint: Delete an org item permanently.
Accepts JSON body with either:
  - id: org-id to locate the item
  - file + pos: direct file location
Optional:
  - include_children: if true, delete subtree even if item has children"
  (condition-case err
      (let* ((content-header (cadr (assoc "Content" headers)))
             (json-data (json-parse-string content-header))
             (id (gethash "id" json-data))
             (file (gethash "file" json-data))
             (position (gethash "pos" json-data))
             (include-children (eq (gethash "include_children" json-data) t))
             (result (org-agenda-api--delete-item id file position include-children)))
        (insert (json-encode result)))
    (error
     (org-agenda-api--log-error-with-backtrace "/delete" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

;;; Category Strategy Support

(defvar org-agenda-api--default-category-prompts
  '(("Title" :type string :required t)
    ("Scheduled" :type date :required nil)
    ("Deadline" :type date :required nil)
    ("Priority" :type string :required nil)
    ("Tags" :type tags :required nil))
  "Default prompts for category capture when none are specified.")

(defun org-agenda-api--parse-strategy-entry (entry)
  "Parse a strategy ENTRY from `org-agenda-api-category-strategies'.
Returns a plist with :strategy, :template, and :prompts keys.
Handles both simple form (NAME . STRATEGY) and plist form
\(NAME :strategy STRATEGY :template TEMPLATE :prompts PROMPTS)."
  (let ((value (cdr entry)))
    (cond
     ;; Plist form: (NAME :strategy STRATEGY :template TEMPLATE :prompts PROMPTS)
     ((and (listp value) (plist-get value :strategy))
      (list :strategy (plist-get value :strategy)
            :template (or (plist-get value :template) "* TODO %?\n")
            :prompts (or (plist-get value :prompts)
                         org-agenda-api--default-category-prompts)))
     ;; Simple form: (NAME . STRATEGY)
     (t
      (list :strategy value
            :template "* TODO %?\n"
            :prompts org-agenda-api--default-category-prompts)))))

(defun org-agenda-api--get-strategy (type-name)
  "Get the strategy registered under TYPE-NAME.
Returns the strategy object or nil if not found."
  (let ((entry (assoc type-name org-agenda-api-category-strategies)))
    (when entry
      (plist-get (org-agenda-api--parse-strategy-entry entry) :strategy))))

(defun org-agenda-api--get-strategy-template (type-name)
  "Get the capture template for strategy TYPE-NAME.
Returns the template string or default if not specified."
  (let ((entry (assoc type-name org-agenda-api-category-strategies)))
    (if entry
        (plist-get (org-agenda-api--parse-strategy-entry entry) :template)
      "* TODO %?\n")))

(defun org-agenda-api--get-strategy-prompts (type-name)
  "Get the prompts for strategy TYPE-NAME.
Returns the prompts list or default prompts if not specified."
  (let ((entry (assoc type-name org-agenda-api-category-strategies)))
    (if entry
        (plist-get (org-agenda-api--parse-strategy-entry entry) :prompts)
      org-agenda-api--default-category-prompts)))

(defun org-agenda-api--list-category-types ()
  "Return a list of registered category type names."
  (mapcar #'car org-agenda-api-category-strategies))

(defun org-agenda-api--get-categories-for-strategy (strategy)
  "Get all categories from STRATEGY.
Returns a list of category strings."
  (when (and strategy (fboundp 'occ-get-categories))
    (occ-get-categories strategy)))

(defun org-agenda-api--get-existing-categories-for-strategy (strategy)
  "Get existing categories from STRATEGY (those with capture locations).
Returns a list of category strings."
  (when (and strategy (fboundp 'occ-get-existing-categories))
    (occ-get-existing-categories strategy)))

(defun org-agenda-api--get-todo-files-for-strategy (strategy)
  "Get TODO files associated with STRATEGY.
Returns a list of file paths."
  (when (and strategy (fboundp 'occ-get-todo-files))
    (occ-get-todo-files strategy)))

(defun org-agenda-api--get-tasks-for-category (strategy category)
  "Get all TODO items under CATEGORY using STRATEGY.
Uses occ-map-entries-for-category to traverse entries."
  (when (and strategy category (fboundp 'occ-get-todo-files))
    (let ((todo-files (occ-get-todo-files strategy))
          (tasks nil))
      (dolist (file todo-files)
        (when (file-exists-p file)
          (with-current-buffer (find-file-noselect file)
            ;; Map over entries for this category
            (when (fboundp 'occ-map-entries-for-category)
              (let ((category-tasks
                     (condition-case nil
                         (occ-map-entries-for-category
                          category
                          (lambda ()
                            (let* ((todo (org-get-todo-state))
                                   (title (org-get-heading t t t t))
                                   (tags (org-get-tags))
                                   (level (org-current-level))
                                   (planning (org-agenda-api--get-planning-info))
                                   (scheduled-time (alist-get 'scheduled-time planning))
                                   (scheduled-has-time (alist-get 'scheduled-has-time planning))
                                   (deadline-time (alist-get 'deadline-time planning))
                                   (deadline-has-time (alist-get 'deadline-has-time planning))
                                   (pos (point))
                                   (org-id (org-entry-get (point) "ID"))
                                   (olpath (org-get-outline-path t))
                                   (priority (org-entry-get (point) "PRIORITY"))
                                   (all-properties (org-agenda-api--get-all-entry-properties)))
                              `(("todo" . ,todo)
                                ("title" . ,title)
                                ("tags" . ,(if tags (vconcat tags) nil))
                                ("level" . ,level)
                                ("scheduled" . ,(org-agenda-api--format-timestamp scheduled-time scheduled-has-time))
                                ("deadline" . ,(org-agenda-api--format-timestamp deadline-time deadline-has-time))
                                ("file" . ,file)
                                ("pos" . ,pos)
                                ("id" . ,org-id)
                                ("category" . ,category)
                                ("olpath" . ,(if olpath (vconcat olpath) nil))
                                ("priority" . ,priority)
                                ("properties" . ,all-properties))))
                          :get-category-from-element
                          (if (fboundp 'org-project-capture-get-category-from-heading)
                              'org-project-capture-get-category-from-heading
                            'org-get-heading))
                       (error nil))))
                (when category-tasks
                  (setq tasks (nconc tasks category-tasks))))))))
      tasks)))

(defservlet category-types application/json ()
  "Endpoint: Return list of registered category strategy types.
Returns an array of type objects with name, hasCategories, and captureTemplate."
  (condition-case err
      (let* ((types (org-agenda-api--list-category-types))
             (type-info (mapcar
                         (lambda (type)
                           (let ((strategy (org-agenda-api--get-strategy type))
                                 (template (org-agenda-api--get-strategy-template type))
                                 (prompts (org-agenda-api--get-strategy-prompts type)))
                             `(("name" . ,type)
                               ("hasCategories" . ,(if (and strategy
                                                            (org-agenda-api--get-categories-for-strategy strategy))
                                                       t :json-false))
                               ("captureTemplate" . ,template)
                               ("prompts" . ,(vconcat
                                              (mapcar
                                               (lambda (prompt)
                                                 (let ((name (car prompt))
                                                       (plist (cdr prompt)))
                                                   `(("name" . ,name)
                                                     ("type" . ,(symbol-name (plist-get plist :type)))
                                                     ("required" . ,(if (plist-get plist :required) t :json-false)))))
                                               prompts))))))
                         types))
             (response `(("types" . ,(vconcat type-info)))))
        (insert (json-encode response)))
    (error
     (org-agenda-api--log-error-with-backtrace "/category-types" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defservlet categories application/json (_path query)
  "Endpoint: Return categories for a given strategy type.
Accepts query params:
  - 'type' (required): The category strategy type name
  - 'existing_only' (optional): If 'true', only return categories with capture locations"
  (condition-case err
      (let* ((type-name (cadr (assoc "type" query)))
             (existing-only (member (cadr (assoc "existing_only" query)) '("true" "1"))))
        (if (or (null type-name) (string= type-name ""))
            (insert (json-encode `(("status" . "error")
                                   ("message" . "Missing required 'type' parameter"))))
          (let ((strategy (org-agenda-api--get-strategy type-name)))
            (if (null strategy)
                (insert (json-encode `(("status" . "error")
                                       ("message" . ,(format "Unknown strategy type: %s" type-name)))))
              (let* ((categories (if existing-only
                                     (org-agenda-api--get-existing-categories-for-strategy strategy)
                                   (org-agenda-api--get-categories-for-strategy strategy)))
                     (todo-files (org-agenda-api--get-todo-files-for-strategy strategy))
                     (response `(("type" . ,type-name)
                                 ("categories" . ,(vconcat categories))
                                 ("todoFiles" . ,(vconcat todo-files)))))
                (insert (json-encode response)))))))
    (error
     (org-agenda-api--log-error-with-backtrace "/categories" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defservlet category-tasks application/json (_path query)
  "Endpoint: Return tasks for a specific category and strategy type.
Accepts query params:
  - 'type' (required): The category strategy type name
  - 'category' (required): The category name"
  (condition-case err
      (let* ((type-name (cadr (assoc "type" query)))
             (category (cadr (assoc "category" query))))
        (cond
         ((or (null type-name) (string= type-name ""))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Missing required 'type' parameter")))))
         ((or (null category) (string= category ""))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Missing required 'category' parameter")))))
         (t
          (let ((strategy (org-agenda-api--get-strategy type-name)))
            (if (null strategy)
                (insert (json-encode `(("status" . "error")
                                       ("message" . ,(format "Unknown strategy type: %s" type-name)))))
              (let* ((tasks (org-agenda-api--get-tasks-for-category strategy category))
                     (response `(("type" . ,type-name)
                                 ("category" . ,category)
                                 ("tasks" . ,(vconcat tasks)))))
                (insert (json-encode response))))))))
    (error
     (org-agenda-api--log-error-with-backtrace "/category-tasks" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defun org-agenda-api--build-category-capture-template (values)
  "Build a capture template string from VALUES.
VALUES is an alist with title, todo, scheduled, deadline, priority, tags, properties.
Returns a template string with all values pre-filled (no interactive prompts)."
  (let* ((title (or (cdr (assoc "title" values)) ""))
         (todo-state (or (cdr (assoc "todo" values)) "TODO"))
         (scheduled (cdr (assoc "scheduled" values)))
         (deadline (cdr (assoc "deadline" values)))
         (priority (cdr (assoc "priority" values)))
         (tags (cdr (assoc "tags" values)))
         (properties (cdr (assoc "properties" values)))
         (parts nil))
    ;; Build headline: * TODO [#A] Title :tag1:tag2:
    (push (format "* %s " todo-state) parts)
    (when (and priority (not (string-empty-p priority)))
      (push (format "[#%s] " (upcase priority)) parts))
    (push title parts)
    (when (and tags (> (length tags) 0))
      (let ((tag-list (if (vectorp tags) (append tags nil) tags)))
        (push (format " :%s:" (mapconcat #'identity tag-list ":")) parts)))
    (push "\n" parts)
    ;; Add SCHEDULED/DEADLINE line if needed
    (let ((planning-parts nil))
      (when (and scheduled (not (string-empty-p scheduled)))
        (let* ((has-time (org-agenda-api--datetime-has-time-p scheduled))
               (time (org-agenda-api--parse-datetime scheduled))
               (org-ts (when time (org-agenda-api--format-org-timestamp time has-time))))
          (when org-ts
            (push (format "SCHEDULED: %s" org-ts) planning-parts))))
      (when (and deadline (not (string-empty-p deadline)))
        (let* ((has-time (org-agenda-api--datetime-has-time-p deadline))
               (time (org-agenda-api--parse-datetime deadline))
               (org-ts (when time (org-agenda-api--format-org-timestamp time has-time))))
          (when org-ts
            (push (format "DEADLINE: %s" org-ts) planning-parts))))
      (when planning-parts
        (push (concat (mapconcat #'identity (nreverse planning-parts) " ") "\n") parts)))
    ;; Add properties drawer
    (push ":PROPERTIES:\n" parts)
    (push (format ":CREATED: %s\n" (format-time-string "[%Y-%m-%d %a %H:%M]" (current-time))) parts)
    (when properties
      (dolist (prop properties)
        (let ((prop-name (car prop))
              (prop-value (cdr prop)))
          (when (and prop-name prop-value (not (string-empty-p prop-value)))
            (push (format ":%s: %s\n" (upcase prop-name) prop-value) parts)))))
    (push ":END:\n" parts)
    ;; Combine all parts
    (apply #'concat (nreverse parts))))

(defun org-agenda-api--capture-to-category (strategy category values)
  "Capture a new entry to CATEGORY using STRATEGY.
VALUES is an alist that may contain:
  - title: The entry title (required)
  - todo: TODO state (default: TODO)
  - scheduled: ISO date/datetime string
  - deadline: ISO date/datetime string
  - priority: A, B, or C
  - tags: list of tag strings
  - properties: alist of property name/value pairs
Returns an alist with status information.

Uses occ-capture with :immediate-finish to leverage org-category-capture's
logic for finding the correct capture location."
  (unless (fboundp 'occ-capture)
    (error "org-category-capture is not loaded"))
  (let* ((title (or (cdr (assoc "title" values)) ""))
         (template-string (org-agenda-api--build-category-capture-template values))
         ;; Create occ-context with immediate-finish option
         (context (make-instance 'occ-context
                                 :category category
                                 :template template-string
                                 :strategy strategy
                                 :options '(:immediate-finish t)))
         ;; Get marker before capture to return file info
         (marker (occ-get-capture-marker context))
         (target-file (when marker (buffer-file-name (marker-buffer marker)))))
    (unless marker
      (error "Could not get capture marker for category: %s" category))
    ;; Use occ-capture which handles all the positioning logic
    (occ-capture context)
    (org-agenda-api--invalidate-cache)
    `(("status" . "created")
      ("category" . ,category)
      ("title" . ,title)
      ("file" . ,target-file))))

(defservlet category-capture application/json (_path _query headers)
  "Endpoint: Capture a new entry to a specific category.
Accepts JSON body with:
  - type: The category strategy type name (required)
  - category: The category name (required)
  - title: Entry title (required)
  - todo: TODO state (optional, default: TODO)
  - scheduled: ISO date/datetime string (optional)
  - deadline: ISO date/datetime string (optional)
  - priority: A, B, or C (optional)
  - tags: array of tag strings (optional)
  - properties: object of property name/value pairs (optional)"
  (condition-case err
      (let* ((content-header (cadr (assoc "Content" headers)))
             (json-data (json-parse-string content-header))
             (type-name (gethash "type" json-data))
             (category (gethash "category" json-data))
             (title (gethash "title" json-data))
             (todo-state (gethash "todo" json-data))
             (scheduled (gethash "scheduled" json-data))
             (deadline (gethash "deadline" json-data))
             (priority (gethash "priority" json-data))
             (tags (gethash "tags" json-data))
             (properties-hash (gethash "properties" json-data))
             ;; Convert properties hash to alist
             (properties (when (hash-table-p properties-hash)
                           (let (alist)
                             (maphash (lambda (k v) (push (cons k v) alist)) properties-hash)
                             alist)))
             ;; Build values alist
             (values `(("title" . ,title)
                       ("todo" . ,todo-state)
                       ("scheduled" . ,(unless (eq scheduled :null) scheduled))
                       ("deadline" . ,(unless (eq deadline :null) deadline))
                       ("priority" . ,(unless (eq priority :null) priority))
                       ("tags" . ,(unless (eq tags :null) tags))
                       ("properties" . ,properties))))
        (cond
         ((or (null type-name) (string= type-name ""))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Missing required 'type' parameter")))))
         ((or (null category) (string= category ""))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Missing required 'category' parameter")))))
         ((or (null title) (string= title ""))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Missing required 'title' parameter")))))
         (t
          (let ((strategy (org-agenda-api--get-strategy type-name)))
            (if (null strategy)
                (insert (json-encode `(("status" . "error")
                                       ("message" . ,(format "Unknown strategy type: %s" type-name)))))
              (let ((result (org-agenda-api--capture-to-category strategy category values)))
                (insert (json-encode result))))))))
    (error
     (org-agenda-api--log-error-with-backtrace "/category-capture" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

;;; Public API

(defun org-agenda-api--warm-cache ()
  "Pre-populate the TODO cache for faster first requests."
  (message "org-agenda-api: Warming cache for %d files..." (length org-agenda-files))
  (let ((start-time (current-time)))
    (org-agenda-api--get-agenda-todos)
    (message "org-agenda-api: Cache warmed in %.2fs (%d items)"
             (float-time (time-subtract (current-time) start-time))
             (length org-agenda-api--todos-cache))))

;;;###autoload
(defun org-agenda-api-start ()
  "Start the org-agenda-api HTTP server."
  (interactive)
  (setq httpd-port org-agenda-api-port)
  (setq org-agenda-api--start-time (current-time))
  (setq org-agenda-api--request-count 0)
  ;; Warm cache before starting server
  (org-agenda-api--warm-cache)
  (httpd-start)
  (message "org-agenda-api: HTTP server started on port %d" org-agenda-api-port))

;;;###autoload
(defun org-agenda-api-stop ()
  "Stop the org-agenda-api HTTP server."
  (interactive)
  (httpd-stop)
  (message "org-agenda-api: HTTP server stopped"))

(provide 'org-agenda-api)
;;; org-agenda-api.el ends here
