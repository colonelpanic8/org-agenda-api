;;; org-agenda-api.el --- JSON HTTP API for org-agenda -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Ivan Malison

;; Author: Ivan Malison <IvanMalison@gmail.com>
;; URL: https://github.com/IvanMalison/org-agenda-api
;; Version: 0.1.0
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
;;   GET /agenda - Returns org-agenda entries
;;       ?span=day|week - Agenda span (default: day)
;;       ?refresh=true - Git pull repos containing agenda files first
;;   GET /get-todays-agenda - Returns scheduled/deadlined items for today
;;   POST /create-todo - Create a new TODO item

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'org-element)
(require 'org-capture)
(require 'json)
(require 'simple-httpd)

;;; Customization

(defgroup org-agenda-api nil
  "JSON HTTP API for org-agenda."
  :group 'org
  :prefix "org-agenda-api-")

(defcustom org-agenda-api-port 2025
  "Port number for the HTTP server."
  :type 'integer
  :group 'org-agenda-api)

(defcustom org-agenda-api-inbox-file "~/org/inbox.org"
  "File where new TODOs are captured."
  :type 'file
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
  (apply #'max
         (mapcar (lambda (file)
                   (if (file-exists-p file)
                       (float-time (file-attribute-modification-time
                                    (file-attributes file)))
                     0))
                 org-agenda-files)))

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

(defun org-agenda-api--get-todo-elements-from-filepath (filepath)
  "Extract all TODO headline elements from FILEPATH.
Uses `org-map-entries' for efficient traversal instead of
expensive `org-element-at-point' calls."
  (with-current-buffer (find-file-noselect filepath)
    (org-map-entries
     (lambda ()
       ;; We're at a headline with a TODO keyword
       ;; Extract properties directly from org functions (much faster than org-element)
       (let ((todo (org-get-todo-state))
             (title (org-get-heading t t t t))  ; no-tags, no-todo, no-priority, no-comment
             (tags (org-get-tags))
             (level (org-current-level))
             (scheduled (org-get-scheduled-time (point)))
             (deadline (org-get-deadline-time (point)))
             (pos (point))
             (org-id (org-entry-get (point) "ID"))
             (olpath (org-get-outline-path t))  ; include current heading
             (notify-before (org-agenda-api--parse-notify-before
                             (org-entry-get (point) "WILD_NOTIFIER_NOTIFY_BEFORE"))))
         ;; Return an alist directly for JSON encoding (skip org-element overhead)
         `(("todo" . ,todo)
           ("title" . ,title)
           ("tags" . ,(if tags (vconcat tags) nil))
           ("level" . ,level)
           ("scheduled" . ,(when scheduled
                             (format-time-string "%Y-%m-%dT%H:%M:%SZ" scheduled)))
           ("deadline" . ,(when deadline
                            (format-time-string "%Y-%m-%dT%H:%M:%SZ" deadline)))
           ("file" . ,filepath)
           ("pos" . ,pos)
           ("id" . ,org-id)
           ("olpath" . ,(if olpath (vconcat olpath) nil))
           ("notifyBefore" . ,(when notify-before (vconcat notify-before))))))
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
  (let ((todo (org-element-property :todo-keyword element))
        (title (org-element-property :raw-value element))
        (tags (org-element-property :tags element))
        (level (org-element-property :level element))
        (scheduled (org-element-property :scheduled element))
        (deadline (org-element-property :deadline element)))
    `(("todo" . ,todo)
      ("title" . ,title)
      ("tags" . ,tags)
      ("level" . ,level)
      ("scheduled" . ,(when scheduled
                        (org-format-timestamp scheduled "%Y-%m-%dT%H:%M:%SZ")))
      ("deadline" . ,(when deadline
                       (org-format-timestamp deadline "%Y-%m-%dT%H:%M:%SZ"))))))

(defun org-agenda-api--item-to-json (item)
  "Convert agenda ITEM to an alist suitable for JSON encoding."
  (let* ((todo (get-text-property 0 'todo-state item))
         (title (substring-no-properties item))
         (tags (get-text-property 0 'tags item))
         (ts-date (get-text-property 0 'ts-date item))
         (scheduled (when ts-date
                      (org-format-timestamp
                       (org-time-from-absolute ts-date)
                       "%Y-%m-%dT%H:%M:%SZ"))))
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

(defun org-agenda-api--extract-entry-data (marker agenda-line)
  "Extract todo data from the org entry at MARKER.
AGENDA-LINE is the raw agenda display text for reference."
  (when (marker-buffer marker)
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (when (org-at-heading-p)
          (let ((todo (org-get-todo-state))
                (title (org-get-heading t t t t))
                (tags (org-get-tags))
                (level (org-current-level))
                (scheduled (org-get-scheduled-time (point)))
                (deadline (org-get-deadline-time (point)))
                (pos (point))
                (filepath (buffer-file-name))
                (org-id (org-entry-get (point) "ID"))
                (olpath (org-get-outline-path t))
                (priority (org-entry-get (point) "PRIORITY"))
                (notify-before (org-agenda-api--parse-notify-before
                                (org-entry-get (point) "WILD_NOTIFIER_NOTIFY_BEFORE"))))
            `(("todo" . ,todo)
              ("title" . ,title)
              ("tags" . ,(if tags (vconcat tags) nil))
              ("level" . ,level)
              ("scheduled" . ,(when scheduled
                                (format-time-string "%Y-%m-%dT%H:%M:%SZ" scheduled)))
              ("deadline" . ,(when deadline
                               (format-time-string "%Y-%m-%dT%H:%M:%SZ" deadline)))
              ("file" . ,filepath)
              ("pos" . ,pos)
              ("id" . ,org-id)
              ("olpath" . ,(if olpath (vconcat olpath) nil))
              ("priority" . ,priority)
              ("notifyBefore" . ,(when notify-before (vconcat notify-before)))
              ("agendaLine" . ,(substring-no-properties agenda-line)))))))))

(defun org-agenda-api--run-agenda (span)
  "Run org-agenda and return entries as a list of JSON-encodable alists.
SPAN should be `day' or `week'."
  (let ((org-agenda-span span)
        (org-agenda-use-time-grid t)
        (org-agenda-start-on-weekday nil)
        (org-agenda-window-setup 'current-window)
        entries)
    ;; Run the agenda
    (save-window-excursion
      (org-agenda-list nil nil (if (eq span 'day) 1 7))
      (with-current-buffer "*Org Agenda*"
        (goto-char (point-min))
        ;; Skip the header lines (date header etc.)
        (while (not (eobp))
          (let* ((line (buffer-substring (line-beginning-position) (line-end-position)))
                 (marker (get-text-property 0 'org-marker line)))
            ;; Only include lines that have an org-marker (actual entries)
            (when marker
              (let ((entry-data (org-agenda-api--extract-entry-data marker line)))
                (when entry-data
                  (push entry-data entries)))))
          (forward-line 1)))
      (kill-buffer "*Org Agenda*"))
    (nreverse entries)))

(defun org-agenda-api--build-capture-template (content)
  "Build a capture template for CONTENT."
  `("d" "Dynamic" entry (file ,org-agenda-api-inbox-file)
    ,(format "* TODO %s" content)
    :immediate-finish t))

(defun org-agenda-api--capture (content)
  "Capture a new TODO with CONTENT."
  (let ((org-capture-templates
         (list (org-agenda-api--build-capture-template content))))
    (org-capture nil "d"))
  (org-agenda-api--invalidate-cache))

;;; Capture Template API Functions

(defun org-agenda-api--get-template (key)
  "Get the API capture template with KEY."
  (assoc key org-agenda-api-capture-templates))

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
  "Get all registered templates as a JSON-encodable alist."
  (mapcar #'org-agenda-api--template-to-json org-agenda-api-capture-templates))

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
         (template-string (nth 4 capture-template))
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
                  result t t))
    ;; Remove %? cursor marker
    (setq result (replace-regexp-in-string "%\\?" "" result t t))
    result))

(defun org-agenda-api--capture-with-template (template-key values)
  "Capture using TEMPLATE-KEY with VALUES for prompts.
VALUES is an alist of (PROMPT-NAME . VALUE) pairs.
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
                            org-agenda-api-inbox-file)))
           (entry-text (org-agenda-api--build-entry-from-template template-entry values)))
      ;; Append entry to target file
      (with-current-buffer (find-file-noselect target-file)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert entry-text)
        (unless (string-suffix-p "\n" entry-text) (insert "\n"))
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

(defservlet get-all-todos application/json (path)
  "Endpoint: Return all TODO items from agenda files as JSON.
Response is wrapped with notification defaults.
Accepts optional query param 'refresh' (true/1) to git pull repos first."
  (let* ((query-string (cadr (split-string (or path "") "?")))
         (params (when query-string (url-parse-query-string query-string)))
         (refresh-param (cadr (assoc "refresh" params)))
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

(defservlet agenda application/json (path)
  "Endpoint: Return org-agenda entries as JSON.
Accepts optional query params:
  - 'span' (day or week, defaults to day)
  - 'refresh' (true/1) to git pull repos first."
  (let* ((query-string (cadr (split-string (or path "") "?")))
         (params (when query-string (url-parse-query-string query-string)))
         (span-param (cadr (assoc "span" params)))
         (refresh-param (cadr (assoc "refresh" params)))
         (git-results (when (member refresh-param '("true" "1"))
                        (org-agenda-api--git-refresh-all)))
         (span (if (string= span-param "week") 'week 'day))
         (entries (org-agenda-api--run-agenda span))
         (response `(("span" . ,(symbol-name span))
                     ("date" . ,(format-time-string "%Y-%m-%d"))
                     ("entries" . ,(vconcat entries)))))
    (when git-results
      (push `("gitRefresh" . ,(vconcat git-results)) response))
    (insert (json-encode response)))
  (org-agenda-api--track-request))

(defservlet create-todo application/json (_path _query headers)
  "Endpoint: Create a new TODO item from JSON body."
  (let* ((content-header (cadr (assoc "Content" headers)))
         (json-data (json-parse-string content-header))
         (title (gethash "title" json-data)))
    (org-agenda-api--capture title)
    (insert (json-encode `(("status" . "created")
                           ("title" . ,title)))))
  (org-agenda-api--track-request))

(defservlet templates application/json ()
  "Endpoint: Return registered capture templates and their prompts."
  (insert (json-encode (org-agenda-api--get-all-templates-json)))
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
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defservlet restart application/json ()
  "Endpoint: Restart Emacs worker(s).
When running under supervisord (ORG_API_SUPERVISOR=true), restarts all workers.
Otherwise, just restarts this worker."
  (let ((use-supervisor (getenv "ORG_API_SUPERVISOR")))
    (insert (json-encode
             `(("status" . ,(if use-supervisor
                                "restarting all workers"
                              "restarting")))))
    ;; Use run-at-time to allow the response to be sent before restarting
    (run-at-time 0.1 nil
                 (lambda ()
                   (if use-supervisor
                       (call-process "supervisorctl" nil nil nil "restart" "emacs:*")
                     (kill-emacs 0))))))

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
              (save-buffer)
              (org-agenda-api--invalidate-cache)
              `(("status" . "completed")
                ("title" . ,title)
                ("oldState" . ,old-state)
                ("newState" . ,new-state)))
          `(("status" . "error")
            ("message" . "No heading found at position")))))))

(defun org-agenda-api--parse-datetime (datetime-string)
  "Parse DATETIME-STRING into an Emacs time value.
Accepts ISO format: YYYY-MM-DD or YYYY-MM-DD HH:MM or YYYY-MM-DDTHH:MM:SS."
  (when (and datetime-string (not (string-empty-p datetime-string)))
    (let* ((normalized (replace-regexp-in-string "T" " " datetime-string))
           (has-time (string-match-p ":" normalized)))
      (condition-case nil
          (if has-time
              (date-to-time (concat normalized ":00"))
            (date-to-time (concat normalized " 00:00:00")))
        (error nil)))))

(defun org-agenda-api--update-todo-at (file pos updates)
  "Update the TODO at FILE and POS with UPDATES alist.
UPDATES can contain: scheduled, deadline, priority.
Returns alist with status and details."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char pos)
      (if (org-at-heading-p)
          (let ((title (org-get-heading t t t t))
                (applied-updates nil))
            ;; Handle scheduled
            (when (assoc "scheduled" updates)
              (let ((scheduled-value (cdr (assoc "scheduled" updates))))
                (if (or (null scheduled-value) (string-empty-p scheduled-value))
                    ;; Clear scheduled
                    (progn
                      (org-schedule '(4))  ; Universal arg removes scheduling
                      (push '("scheduled" . nil) applied-updates))
                  ;; Set scheduled
                  (let ((time (org-agenda-api--parse-datetime scheduled-value)))
                    (when time
                      (org-schedule nil time)
                      (push `("scheduled" . ,scheduled-value) applied-updates))))))
            ;; Handle deadline
            (when (assoc "deadline" updates)
              (let ((deadline-value (cdr (assoc "deadline" updates))))
                (if (or (null deadline-value) (string-empty-p deadline-value))
                    ;; Clear deadline
                    (progn
                      (org-deadline '(4))  ; Universal arg removes deadline
                      (push '("deadline" . nil) applied-updates))
                  ;; Set deadline
                  (let ((time (org-agenda-api--parse-datetime deadline-value)))
                    (when time
                      (org-deadline nil time)
                      (push `("deadline" . ,deadline-value) applied-updates))))))
            ;; Handle priority
            (when (assoc "priority" updates)
              (let ((priority-value (cdr (assoc "priority" updates))))
                (if (or (null priority-value) (string-empty-p priority-value))
                    ;; Clear priority
                    (progn
                      (org-priority ?\s)  ; Space removes priority
                      (push '("priority" . nil) applied-updates))
                  ;; Set priority (A, B, or C)
                  (let ((priority-char (string-to-char (upcase priority-value))))
                    (when (memq priority-char '(?A ?B ?C))
                      (org-priority priority-char)
                      (push `("priority" . ,priority-value) applied-updates))))))
            (save-buffer)
            (org-agenda-api--invalidate-cache)
            `(("status" . "updated")
              ("title" . ,title)
              ("updates" . ,applied-updates)))
        `(("status" . "error")
          ("message" . "No heading found at position"))))))

(defservlet update application/json (_path _query headers)
  "Endpoint: Update a TODO's scheduled date, deadline, or priority.
Accepts JSON body with:
  - id: org-id of the todo (preferred)
  - file: file path (fallback)
  - pos: position in file (fallback)
  - title: heading title (for verification)
  - scheduled: ISO date/datetime string or null to clear
  - deadline: ISO date/datetime string or null to clear
  - priority: A, B, C, or null to clear"
  (condition-case err
      (let* ((content-header (cadr (assoc "Content" headers)))
             (json-data (json-parse-string content-header))
             (id (gethash "id" json-data))
             (file (gethash "file" json-data))
             (pos (gethash "pos" json-data))
             (title (gethash "title" json-data))
             (scheduled (gethash "scheduled" json-data))
             (deadline (gethash "deadline" json-data))
             (priority (gethash "priority" json-data))
             (location nil)
             (updates nil))
        ;; Build updates alist (include keys even if value is nil, to signal clearing)
        (when (gethash "scheduled" json-data json-data)
          (push (cons "scheduled" (if (eq scheduled :null) nil scheduled)) updates))
        (when (gethash "deadline" json-data json-data)
          (push (cons "deadline" (if (eq deadline :null) nil deadline)) updates))
        (when (gethash "priority" json-data json-data)
          (push (cons "priority" (if (eq priority :null) nil priority)) updates))
        ;; Try to find by ID first
        (setq location (org-agenda-api--find-todo-by-id id))
        ;; Fall back to file+pos+title
        (unless location
          (setq location (org-agenda-api--find-todo-by-file-pos-title file pos title)))
        (if location
            (let ((result (org-agenda-api--update-todo-at
                           (car location) (cdr location) updates)))
              (insert (json-encode result)))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Todo not found"))))))
    (error
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
        (if location
            (let ((result (org-agenda-api--complete-todo-at
                           (car location) (cdr location) new-state)))
              (insert (json-encode result)))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Todo not found"))))))
    (error
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
