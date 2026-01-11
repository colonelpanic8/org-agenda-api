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

;;; Internal Functions

(defun org-agenda-api--get-todo-elements-from-filepath (filepath)
  "Extract all TODO headline elements from FILEPATH."
  (let ((todo-elements nil))
    (with-current-buffer (find-file-noselect filepath)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward org-todo-regexp nil t)
          (let* ((element (org-element-at-point))
                 (type (org-element-type element)))
            (when (eq type 'headline)
              (let ((todo (org-element-property :todo-keyword element)))
                (when todo
                  (push element todo-elements))))))))
    todo-elements))

(defun org-agenda-api--get-agenda-todos ()
  "Get all TODO elements from `org-agenda-files'."
  (mapcan #'org-agenda-api--get-todo-elements-from-filepath org-agenda-files))

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

(defun org-agenda-api--build-capture-template (content)
  "Build a capture template for CONTENT."
  `("d" "Dynamic" entry (file ,org-agenda-api-inbox-file)
    ,(format "* TODO %s" content)
    :immediate-finish t))

(defun org-agenda-api--capture (content)
  "Capture a new TODO with CONTENT."
  (let ((org-capture-templates
         (list (org-agenda-api--build-capture-template content))))
    (org-capture nil "d")))

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
      `(("status" . "created")
        ("template" . ,template-key)))))

;;; HTTP Endpoints

(defservlet get-all-todos application/json ()
  "Endpoint: Return all TODO items from agenda files as JSON."
  (insert (json-encode
           (mapcar #'org-agenda-api--element-to-json
                   (org-agenda-api--get-agenda-todos)))))

(defservlet get-todays-agenda application/json ()
  "Endpoint: Return today's scheduled and deadlined items as JSON."
  (insert (json-encode
           (mapcar #'org-agenda-api--item-to-json
                   (org-agenda-api--get-today-agenda)))))

(defservlet create-todo application/json (_path _query headers)
  "Endpoint: Create a new TODO item from JSON body."
  (let* ((content-header (cadr (assoc "Content" headers)))
         (json-data (json-parse-string content-header))
         (title (gethash "title" json-data)))
    (org-agenda-api--capture title)
    (insert (json-encode `(("status" . "created")
                           ("title" . ,title))))))

(defservlet templates application/json ()
  "Endpoint: Return registered capture templates and their prompts."
  (insert (json-encode (org-agenda-api--get-all-templates-json))))

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
                            ("message" . ,(error-message-string err))))))))

;;; Public API

;;;###autoload
(defun org-agenda-api-start ()
  "Start the org-agenda-api HTTP server."
  (interactive)
  (setq httpd-port org-agenda-api-port)
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
