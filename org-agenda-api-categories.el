;;; org-agenda-api-categories.el --- Category strategy support for org-agenda-api -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison
;; Author: Ivan Malison <IvanMalison@gmail.com>

;;; Commentary:
;; Optional category strategy support for org-project-capture integration.
;; This module can be loaded optionally when org-category-capture is available.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'json)
(require 'simple-httpd)
(require 'org-agenda-api-core)
(require 'org-agenda-api-data)

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
                                   (scheduled-end-time (alist-get 'scheduled-end-time planning))
                                   (scheduled-end-has-time (alist-get 'scheduled-end-has-time planning))
                                   (deadline-time (alist-get 'deadline-time planning))
                                   (deadline-has-time (alist-get 'deadline-has-time planning))
                                   (deadline-end-time (alist-get 'deadline-end-time planning))
                                   (deadline-end-has-time (alist-get 'deadline-end-has-time planning))
                                   (pos (point))
                                   (org-id (org-entry-get (point) "ID"))
                                   (olpath (org-get-outline-path t))
                                   (priority (org-entry-get (point) "PRIORITY"))
                                   (all-properties (org-agenda-api--get-all-entry-properties))
                                   (timestamps (org-agenda-api--get-entry-timestamps)))
                              `(("todo" . ,todo)
                                ("title" . ,title)
                                ("tags" . ,(if tags (vconcat tags) nil))
                                ("level" . ,level)
                                ("scheduled" . ,(org-agenda-api--format-timestamp scheduled-time scheduled-has-time))
                                ,@(when scheduled-end-time
                                    `(("scheduledEnd" . ,(org-agenda-api--format-timestamp scheduled-end-time scheduled-end-has-time))))
                                ("deadline" . ,(org-agenda-api--format-timestamp deadline-time deadline-has-time))
                                ,@(when deadline-end-time
                                    `(("deadlineEnd" . ,(org-agenda-api--format-timestamp deadline-end-time deadline-end-has-time))))
                                ,@(when timestamps
                                    `(("timestamps" . ,(vconcat timestamps))))
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

;;; Category Capture Functions

(defun org-agenda-api--build-category-capture-template (values)
  "Build a capture template string from VALUES.
VALUES is an alist with title, todo, scheduled, scheduledRepeater, deadline,
deadlineRepeater, priority, tags, properties.
Returns a template string with all values pre-filled (no interactive prompts)."
  (let* ((title (or (cdr (assoc "title" values)) ""))
         (todo-state (or (cdr (assoc "todo" values)) "TODO"))
         (scheduled (cdr (assoc "scheduled" values)))
         (scheduled-repeater (cdr (assoc "scheduledRepeater" values)))
         (deadline (cdr (assoc "deadline" values)))
         (deadline-repeater (cdr (assoc "deadlineRepeater" values)))
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
    ;; Add SCHEDULED/DEADLINE line if needed (with optional repeaters)
    (let ((planning-parts nil))
      (when (and scheduled (not (string-empty-p scheduled)))
        (let* ((has-time (org-agenda-api--datetime-has-time-p scheduled))
               (time (org-agenda-api--parse-datetime scheduled))
               (org-ts (when time (org-agenda-api--format-org-timestamp-with-repeater
                                   time has-time scheduled-repeater))))
          (when org-ts
            (push (format "SCHEDULED: %s" org-ts) planning-parts))))
      (when (and deadline (not (string-empty-p deadline)))
        (let* ((has-time (org-agenda-api--datetime-has-time-p deadline))
               (time (org-agenda-api--parse-datetime deadline))
               (org-ts (when time (org-agenda-api--format-org-timestamp-with-repeater
                                   time has-time deadline-repeater))))
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

;;; Category Types Helper

(defun org-agenda-api--get-category-types ()
  "Return category types data as an alist suitable for JSON encoding.
Returns an alist with a 'types' key containing a vector of type objects."
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
                     types)))
    `(("types" . ,(vconcat type-info)))))

;;; Category Endpoints

(defservlet category-types application/json ()
  "Endpoint: Return list of registered category strategy types.
Returns an array of type objects with name, hasCategories, and captureTemplate."
  (condition-case err
      (insert (json-encode (org-agenda-api--get-category-types)))
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

(provide 'org-agenda-api-categories)
;;; org-agenda-api-categories.el ends here
