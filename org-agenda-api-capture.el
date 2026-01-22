;;; org-agenda-api-capture.el --- Capture functionality for org-agenda-api -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison
;; Author: Ivan Malison <IvanMalison@gmail.com>

;;; Commentary:
;; Capture template management and execution for the API.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-capture)
(require 'org-agenda-api-core)
(require 'org-agenda-api-data)

;;; Capture Template Functions

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
This substitutes values into the template without interactive prompts.
Uses `org-capture-fill-template' to handle standard escape sequences
like %(sexp), %U, %t, etc."
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
    ;; Replace %^{Name} with the value (interactive prompts we're filling programmatically)
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
    ;; Replace %? with Title value if present, otherwise remove it
    ;; (do this before org-capture-fill-template which would leave %? for cursor)
    (let ((title-value (cdr (assoc "Title" values))))
      (setq result (replace-regexp-in-string
                    "%\\?"
                    (or title-value "")
                    result t t)))
    ;; Use org-capture-fill-template to handle all other escape sequences:
    ;; %(sexp), %U, %u, %T, %t, %a, %c, %i, etc.
    (require 'org-capture)
    (setq result (org-capture-fill-template result))
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

;;; Capture Readiness Check

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

(provide 'org-agenda-api-capture)
;;; org-agenda-api-capture.el ends here
