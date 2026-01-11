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
