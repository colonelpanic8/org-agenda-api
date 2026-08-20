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

(define-error 'org-agenda-api-capture-client-error
  "Invalid noninteractive capture request")

(defun org-agenda-api--capture-client-error (format-string &rest args)
  "Signal a client capture error using FORMAT-STRING and ARGS."
  (signal 'org-agenda-api-capture-client-error
          (list (apply #'format format-string args))))

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

(defun org-agenda-api--capture-value-component (value key)
  "Get KEY from timestamp VALUE, which may be a hash table or alist."
  (cond
   ((hash-table-p value) (gethash key value))
   ((listp value) (cdr (assoc key value)))
   (t nil)))

(defun org-agenda-api--parse-capture-date-value (value)
  "Return (DATE TIME) parsed from capture prompt VALUE.
VALUE may be an ISO date/datetime string or an object with date and time
fields.  TIME is nil when VALUE contains only a date."
  (let (date time)
    (cond
     ((stringp value)
      (unless (string-match
               (concat
                "\\`\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)"
                "\\(?:[T ]\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)"
                "\\(?::[0-9]\\{2\\}\\(?:\\.[0-9]+\\)?\\)?"
                "\\(?:Z\\|[+-][0-9]\\{2\\}:[0-9]\\{2\\}\\)?\\)?\\'")
               value)
        (org-agenda-api--capture-client-error
         "Invalid date value: %s" value))
      (setq date (match-string 1 value)
            time (match-string 2 value)))
     ((or (hash-table-p value) (listp value))
      (setq date (org-agenda-api--capture-value-component value "date")
            time (org-agenda-api--capture-value-component value "time")))
     ((null value)
      (setq date nil))
     (t
      (org-agenda-api--capture-client-error
       "Invalid date value: %S" value)))
    (when (and date
               (not (string-match-p
                     "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" date)))
      (org-agenda-api--capture-client-error
       "Invalid date value: %s" date))
    (when (and time
               (not (string-match-p "\\`[0-9]\\{2\\}:[0-9]\\{2\\}\\'" time)))
      (org-agenda-api--capture-client-error
       "Invalid time value: %s" time))
    (list date time)))

(defun org-agenda-api--format-prompt-timestamp (value suffix)
  "Convert prompt VALUE to an Org timestamp according to SUFFIX.
The lowercase t/u suffixes produce date-only timestamps.  Uppercase T/U
preserve a supplied time.  The u/U forms produce inactive timestamps."
  (pcase-let ((`(,date ,time)
               (org-agenda-api--parse-capture-date-value value)))
    (if (not date)
        ""
      (let* ((include-time (memq suffix '(?T ?U)))
             (inactive (memq suffix '(?u ?U)))
             (timestamp-input (concat date " " (or time "00:00") ":00"))
             (parsed-time
              (condition-case nil
                  (date-to-time timestamp-input)
                (error
                 (org-agenda-api--capture-client-error
                  "Invalid date-time value: %s%s"
                  date (if time (concat " " time) "")))))
             (contents (format-time-string
                        (if (and include-time time)
                            "%Y-%m-%d %a %H:%M"
                          "%Y-%m-%d %a")
                        parsed-time)))
        (concat (if inactive "[" "<") contents (if inactive "]" ">"))))))

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
         (result template-string)
         (prompt-regexp
          "%\\^{\\([^}|]+\\)\\(?:|[^}]*\\)?}\\([tTuUgGC]\\)?"))
    ;; Replace named prompts, including choice/default forms, without invoking
    ;; Org's interactive prompt reader.
    (while (string-match prompt-regexp result)
      (let* ((name (match-string 1 result))
             (suffix-string (match-string 2 result))
             (suffix (and suffix-string (aref suffix-string 0)))
             (prompt (assoc name prompts))
             (value-entry (assoc name values))
             (ptype (and prompt (plist-get (cdr prompt) :type)))
             (value (cdr value-entry))
             (formatted-value
              (save-match-data
                (cond
                 ((memq suffix '(?t ?T ?u ?U))
                  (org-agenda-api--format-prompt-timestamp value suffix))
                 ((memq suffix '(?g ?G))
                  (org-agenda-api--format-tags value))
                 ((eq ptype 'date)
                  (org-agenda-api--format-prompt-timestamp value ?t))
                 ((eq ptype 'tags)
                  (org-agenda-api--format-tags value))
                 ((null value) "")
                 ((stringp value) value)
                 (t (format "%s" value))))))
        ;; An unregistered prompt cannot be supplied through the advertised API
        ;; contract, so reject it before Org can open a minibuffer.
        (unless prompt
          (org-agenda-api--capture-client-error
           "Template contains unregistered interactive prompt: %s" name))
        (setq result (replace-match formatted-value t t result))))
    ;; Replace %? with Title value if present, otherwise remove it
    ;; (do this before org-capture-fill-template which would leave %? for cursor)
    (let ((title-value (cdr (assoc "Title" values))))
      (setq result (replace-regexp-in-string
                    "%\\?"
                    (or title-value "")
                    result t t)))
    ;; Any remaining %^ escape is interactive (for example anonymous %^T).
    ;; Calling `org-capture-fill-template' with it in a headless server would
    ;; enter the minibuffer and wedge the worker.
    (when (string-match "%\\^" result)
      (org-agenda-api--capture-client-error
       "Template contains unsupported anonymous interactive escape: %s"
       (substring result (match-beginning 0)
                  (min (length result) (+ (match-beginning 0) 12)))))
    ;; Use org-capture-fill-template to handle all other escape sequences:
    ;; %(sexp), %U, %u, %T, %t, %a, %c, %i, etc.
    (require 'org-capture)
    (setq result (org-capture-fill-template result))
    result))

(defun org-agenda-api--capture-with-template (template-key values)
  "Capture using TEMPLATE-KEY with VALUES for prompts.
VALUES is an alist of (PROMPT-NAME . VALUE) pairs.
In addition to template prompts, VALUES may contain universal org fields:
  - scheduled: object {date, time?, repeater?}
  - deadline: object {date, time?, repeater?}
  - priority: A, B, or C
  - tags: list of tag strings
  - state: TODO state keyword (also accepts \"todo\" for backwards compatibility)
These are applied after the entry is created.
Returns an alist with status information."
  (let ((template-entry (org-agenda-api--get-template template-key)))
    (unless template-entry
      (org-agenda-api--capture-client-error
       "Unknown template: %s" template-key))
    (let ((validation-error (org-agenda-api--validate-capture-values template-entry values)))
      (when validation-error
        (org-agenda-api--capture-client-error "%s" validation-error)))
    (let* ((plist (cdr template-entry))
           (capture-template (plist-get plist :template))
           (target-file (let ((target (nth 3 capture-template)))
                          (if (and (listp target) (eq (car target) 'file))
                              (cadr target)
                            (org-agenda-api--get-default-capture-target))))
           (entry-text (org-agenda-api--build-entry-from-template template-entry values))
           ;; Extract universal fields from values (scheduled/deadline are now objects)
           (scheduled (cdr (assoc "scheduled" values)))
           (deadline (cdr (assoc "deadline" values)))
           (priority (cdr (assoc "priority" values)))
           (tags (cdr (assoc "tags" values)))
           ;; Accept both "state" and "todo" for backwards compatibility
           (todo-state (or (cdr (assoc "state" values))
                           (cdr (assoc "todo" values))))
           ;; org-capture template properties live in the tail after the
           ;; template body (key description type target body . plist).
           (prepare-finalize (plist-get (nthcdr 5 capture-template)
                                        :prepare-finalize))
           (finalize-error nil)
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
            ;; Apply scheduled - convert timestamp object to org format
            (when scheduled
              (let ((org-ts (org-agenda-api--timestamp-to-org scheduled)))
                (when org-ts
                  (org-schedule nil org-ts))))
            ;; Apply deadline - convert timestamp object to org format
            (when deadline
              (let ((org-ts (org-agenda-api--timestamp-to-org deadline)))
                (when org-ts
                  (org-deadline nil org-ts))))
            ;; Apply tags
            (when (and tags (> (length tags) 0))
              (let ((tag-list (if (vectorp tags) (append tags nil) tags)))
                (org-set-tags tag-list)))
            ;; Run the template's :prepare-finalize function with point on the
            ;; new entry. org-capture would call this in the capture buffer;
            ;; we insert directly, so it has to be invoked here or the entry
            ;; is left half-built (e.g. a vocabulary entry that never becomes
            ;; an org-fc card). Failures are reported rather than raised: the
            ;; entry is already written, and losing it to a missing optional
            ;; package would be worse than returning it un-finalized.
            (when (functionp prepare-finalize)
              (condition-case err
                  (funcall prepare-finalize)
                (error
                 (setq finalize-error (error-message-string err))
                 (message "org-agenda-api: :prepare-finalize failed for %s: %s"
                          template-key finalize-error))))))
        (save-buffer))
      (org-agenda-api--invalidate-cache)
      `(("status" . "created")
        ("template" . ,template-key)
        ,@(when finalize-error
            `(("prepare_finalize_error" . ,finalize-error)))))))

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
