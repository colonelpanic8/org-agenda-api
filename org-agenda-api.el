;;; org-agenda-api.el --- JSON HTTP API for org-agenda -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison

;; Author: Ivan Malison <IvanMalison@gmail.com>
;; URL: https://github.com/IvanMalison/org-agenda-api
;; Version: 4.0.2
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
;; For API documentation, see README.md

;;; Code:

;; Required modules
(require 'org-agenda-api-core)
(require 'org-agenda-api-data)
(require 'org-agenda-api-capture)
(require 'org-agenda-api-mutations)
(require 'org-agenda-api-endpoints)

;; Optional modules - load if dependencies available
(require 'org-agenda-api-categories nil t)
(require 'org-agenda-api-window-habit nil t)

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
