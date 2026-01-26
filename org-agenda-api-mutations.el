;;; org-agenda-api-mutations.el --- Mutation operations for org-agenda-api -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison
;; Author: Ivan Malison <IvanMalison@gmail.com>

;;; Commentary:
;; Functions for modifying org entries: complete, update, delete.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-agenda-api-core)
(require 'org-agenda-api-data)

(defun org-agenda-api--add-logbook-state-change (old-state new-state &optional time)
  "Add a state change entry to the LOGBOOK drawer.
OLD-STATE and NEW-STATE are the state strings.
TIME is an optional encoded time (defaults to current time).
Must be called with point at an org heading."
  (let* ((time (or time (current-time)))
         (time-str (format-time-string "[%Y-%m-%d %a %H:%M]" time))
         (entry (format "- State %-13s from %-13s %s"
                        (format "\"%s\"" new-state)
                        (format "\"%s\"" old-state)
                        time-str))
         (drawer-name (or (and (boundp 'org-log-into-drawer)
                               (stringp org-log-into-drawer)
                               org-log-into-drawer)
                          "LOGBOOK")))
    (save-excursion
      (org-back-to-heading t)
      (let ((end-of-heading (save-excursion (outline-next-heading) (point))))
        ;; Look for existing LOGBOOK drawer
        (if (re-search-forward
             (format "^[ \t]*:%s:[ \t]*$" (regexp-quote drawer-name))
             end-of-heading t)
            ;; Found existing drawer - insert at beginning
            (progn
              (forward-line 1)
              (insert "  " entry "\n"))
          ;; No drawer - create one after heading and properties
          (org-end-of-meta-data t)
          (insert "  :" drawer-name ":\n  " entry "\n  :END:\n"))))))

(defun org-agenda-api--extract-logbook-entry-timestamp (entry-text)
  "Extract timestamp from ENTRY-TEXT (a logbook entry string).
Returns an encoded time value for sorting, or nil if no timestamp found."
  (when (string-match org-ts-regexp-inactive entry-text)
    (let ((ts-string (match-string 1 entry-text)))
      (when ts-string
        (org-time-string-to-time (concat "[" ts-string "]"))))))

(defun org-agenda-api--reorder-logbook-entries ()
  "Reorder LOGBOOK entries by timestamp (newest first).
Should be called with point at the org heading.
Returns t if entries were reordered, nil otherwise."
  (save-excursion
    (let ((drawer-name (cond
                        ((and (boundp 'org-log-into-drawer)
                              (stringp org-log-into-drawer))
                         org-log-into-drawer)
                        (t "LOGBOOK")))
          (end-of-subtree (save-excursion (org-end-of-subtree t) (point))))
      (when (re-search-forward
             (format "^[ \t]*:%s:[ \t]*$" (regexp-quote drawer-name))
             end-of-subtree t)
        (let ((drawer-start (point))
              (drawer-end (save-excursion
                           (re-search-forward "^[ \t]*:END:[ \t]*$" end-of-subtree t)
                           (match-beginning 0)))
              (entries nil)
              (current-entry-start nil)
              (current-entry-lines nil))
          (when drawer-end
            ;; Parse entries - each entry starts with "- " and may have continuation lines
            (goto-char drawer-start)
            (forward-line 1)
            (while (< (point) drawer-end)
              (let ((line (buffer-substring (line-beginning-position) (line-end-position))))
                (cond
                 ;; New entry starts with "- "
                 ((string-match "^[ \t]*- " line)
                  ;; Save previous entry if exists
                  (when current-entry-lines
                    (push (cons (org-agenda-api--extract-logbook-entry-timestamp
                                 (car current-entry-lines))
                                (nreverse current-entry-lines))
                          entries))
                  (setq current-entry-lines (list line)))
                 ;; Continuation line (indented, not starting with "- " or ":")
                 ((and current-entry-lines
                       (string-match "^[ \t]+" line)
                       (not (string-match "^[ \t]*:" line)))
                  (push line current-entry-lines))
                 ;; Other lines (empty, etc) - ignore
                 (t nil)))
              (forward-line 1))
            ;; Don't forget the last entry
            (when current-entry-lines
              (push (cons (org-agenda-api--extract-logbook-entry-timestamp
                           (car current-entry-lines))
                          (nreverse current-entry-lines))
                    entries))
            ;; Sort entries by timestamp (newest first)
            ;; Entries without timestamps go to the end
            (setq entries (nreverse entries))
            ;; Save original order before sorting (sort is destructive)
            (let* ((original-order (mapcar #'car entries))
                   (sorted-entries
                    (sort entries
                          (lambda (a b)
                            (let ((time-a (car a))
                                  (time-b (car b)))
                              (cond
                               ((and time-a time-b)
                                (time-less-p time-b time-a))  ; newest first
                               (time-a t)   ; entries with timestamps before those without
                               (t nil))))))
                   (new-order (mapcar #'car sorted-entries)))
              ;; Check if order changed
              (unless (equal original-order new-order)
                ;; Rewrite the drawer contents
                (goto-char drawer-start)
                (forward-line 1)
                (delete-region (point) drawer-end)
                (dolist (entry sorted-entries)
                  (dolist (line (cdr entry))
                    (insert line "\n")))
                t))))))))

(defun org-agenda-api--complete-todo-at (file pos &optional new-state override-date)
  "Mark the TODO at FILE and POS as complete.
NEW-STATE defaults to DONE if not specified.
OVERRIDE-DATE, if provided, should be an encoded time value that will be used
as the effective date for the state change (affects LOGBOOK timestamps).
Returns alist with status and details."
  (let ((new-state (or new-state "DONE")))
    (with-current-buffer (find-file-noselect file t)  ; t = suppress warnings
      ;; Force re-read from disk to avoid stale buffer issues
      (revert-buffer t t t)
      (save-excursion
        (goto-char pos)
        (if (org-at-heading-p)
            (let ((old-state (org-get-todo-state))
                  (title (org-get-heading t t t t)))
              ;; Call org-todo and run post-command-hook, optionally with date override.
              ;; The post-command-hook must be inside the cl-letf because org-add-log-note
              ;; is added to post-command-hook and uses org-current-effective-time when run.
              ;; We also override current-time because some org-mode code paths use it directly.
              (if override-date
                  (progn
                    (cl-letf (((symbol-function 'current-time)
                               (lambda (&rest _) override-date))
                              ((symbol-function 'org-current-effective-time)
                               (lambda (&rest _) override-date))
                              ((symbol-function 'org-today)
                               (lambda (&rest _) (time-to-days override-date))))
                      (org-todo new-state)
                      ;; Run post-command-hook inside the override scope
                      (run-hooks 'post-command-hook))
                    ;; Reorder logbook entries to maintain chronological order
                    ;; (override-date may have inserted entry out of order)
                    (org-back-to-heading t)
                    (org-agenda-api--reorder-logbook-entries))
                (progn
                  (org-todo new-state)
                  ;; Run post-command-hook to trigger org-mode's state change logging
                  ;; (LOGBOOK entries). In non-interactive contexts, org-add-log-note
                  ;; is added to post-command-hook but never runs without this.
                  (run-hooks 'post-command-hook)))
              ;; Force save to disk using save-buffer (simpler, handles file modes correctly)
              (set-buffer-modified-p t)
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

(defun org-agenda-api--update-todo-at (file pos updates)
  "Update the TODO at FILE and POS with UPDATES alist.
UPDATES can contain: new_title, scheduled, deadline, priority, tags, properties, body.
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
            ;; Handle scheduled - accepts object {date, time?, repeater?}
            (when (assoc "scheduled" updates)
              (let ((scheduled-value (cdr (assoc "scheduled" updates))))
                (if (or (null scheduled-value) (eq scheduled-value :json-null))
                    ;; Clear scheduled
                    (progn
                      (org-schedule '(4))  ; Universal arg removes scheduling
                      (push '("scheduled" . nil) applied-updates))
                  ;; Set scheduled - convert timestamp object to org format
                  (let ((org-ts (org-agenda-api--timestamp-to-org scheduled-value)))
                    (when org-ts
                      (org-schedule nil org-ts)
                      (push `("scheduled" . ,scheduled-value) applied-updates))))))
            ;; Handle deadline - accepts object {date, time?, repeater?}
            (when (assoc "deadline" updates)
              (let ((deadline-value (cdr (assoc "deadline" updates))))
                (if (or (null deadline-value) (eq deadline-value :json-null))
                    ;; Clear deadline
                    (progn
                      (org-deadline '(4))  ; Universal arg removes deadline
                      (push '("deadline" . nil) applied-updates))
                  ;; Set deadline - convert timestamp object to org format
                  (let ((org-ts (org-agenda-api--timestamp-to-org deadline-value)))
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
            ;; Handle body - the content after metadata, before next heading
            (when (assoc "body" updates)
              (let ((body-value (cdr (assoc "body" updates))))
                (save-excursion
                  ;; Go to end of heading line
                  (org-back-to-heading t)
                  (let ((heading-end (line-end-position))
                        (entry-end (save-excursion
                                     (org-end-of-subtree t t)
                                     ;; Don't include the final newline before next heading
                                     (skip-chars-backward "\n")
                                     (point)))
                        (content-start nil))
                    ;; Move past heading line
                    (goto-char heading-end)
                    (forward-line 1)
                    ;; Skip SCHEDULED, DEADLINE, CLOSED lines
                    (while (and (< (point) entry-end)
                                (looking-at "^\\s-*\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):"))
                      (forward-line 1))
                    ;; Skip properties drawer if present
                    (when (looking-at "^\\s-*:PROPERTIES:")
                      (re-search-forward "^\\s-*:END:" entry-end t)
                      (forward-line 1))
                    ;; Skip logbook drawer if present
                    (when (looking-at "^\\s-*:LOGBOOK:")
                      (re-search-forward "^\\s-*:END:" entry-end t)
                      (forward-line 1))
                    ;; Now we're at the start of body content
                    (setq content-start (point))
                    ;; Find end of body (before child headings)
                    (let ((body-end (save-excursion
                                      (if (re-search-forward "^\\*+ " entry-end t)
                                          (line-beginning-position)
                                        entry-end))))
                      ;; Delete existing body content
                      (delete-region content-start body-end)
                      ;; Insert new body if provided
                      (goto-char content-start)
                      (when (and body-value
                                 (not (eq body-value :json-null))
                                 (not (string-empty-p body-value)))
                        (insert body-value)
                        (unless (bolp) (insert "\n")))
                      (push `("body" . ,body-value) applied-updates))))))
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

(defun org-agenda-api--delete-error (code message &rest format-args)
  "Signal a delete error with CODE and MESSAGE.
FORMAT-ARGS are passed to `format' with MESSAGE."
  (signal 'org-agenda-api-delete-error
          (list code (apply #'format message format-args))))

(define-error 'org-agenda-api-delete-error "org-agenda-api delete error")

(defun org-agenda-api--delete-item (id file position include-children)
  "Delete an org item identified by ID or FILE+POSITION.
If INCLUDE-CHILDREN is nil and item has children, return error.
Returns alist with deletion result."
  ;; Validate input parameters
  (unless (or id (and file position))
    (org-agenda-api--delete-error
     "MISSING_PARAMS"
     "Must provide either 'id' or both 'file' and 'pos'. Got: id=%S, file=%S, pos=%S"
     id file position))

  ;; Locate the item
  (let* ((location (cond
                    (id
                     (let ((found (org-id-find id)))
                       (unless found
                         (org-agenda-api--delete-error
                          "ID_NOT_FOUND"
                          "No item found with org-id '%s'. The ID may have been deleted or changed."
                          id))
                       found))
                    ((and file position)
                     (cons file position))))
         ;; Expand file path to match org-agenda-files format
         (target-file (expand-file-name (car location)))
         (target-pos (cdr location)))

    (unless (file-exists-p target-file)
      (org-agenda-api--delete-error
       "FILE_NOT_FOUND"
       "File does not exist: %s"
       target-file))

    ;; Verify file is in agenda files (security check)
    (unless (member target-file (org-agenda-files))
      (org-agenda-api--delete-error
       "FILE_NOT_IN_AGENDA"
       "File '%s' is not in org-agenda-files. Only items in agenda files can be deleted."
       target-file))

    ;; Open file and navigate to position
    (with-current-buffer (find-file-noselect target-file)
      (widen)
      (goto-char target-pos)

      ;; Verify we're at a heading
      (unless (org-at-heading-p)
        (let ((actual-content (buffer-substring-no-properties
                               (line-beginning-position)
                               (min (+ (line-beginning-position) 80) (line-end-position)))))
          (org-agenda-api--delete-error
           "INVALID_POSITION"
           "Position %d in file '%s' is not at a headline. Content at position: '%s'"
           target-pos target-file actual-content)))

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
          (org-agenda-api--delete-error
           "HAS_CHILDREN"
           "Item '%s' has %d child heading(s). Set include_children=true to delete the entire subtree, or delete children first."
           title children-count))

        ;; Delete the subtree
        (condition-case err
            (progn
              (org-cut-subtree)
              (save-buffer))
          (error
           (org-agenda-api--delete-error
            "DELETE_FAILED"
            "Failed to delete subtree for '%s': %s"
            title (error-message-string err))))

        ;; Invalidate cache
        (org-agenda-api--invalidate-cache)

        ;; Return result
        (if (> children-count 0)
            `(("deleted" . t)
              ("title" . ,title)
              ("children_deleted" . ,children-count))
          `(("deleted" . t)
            ("title" . ,title)))))))

(defun org-agenda-api--delete-logbook-entry (file pos date &optional entry-type)
  "Delete a LOGBOOK entry at DATE for the heading at FILE and POS.
DATE should be a string like \"2024-01-15\".
ENTRY-TYPE if provided filters to only delete entries of that type
\(e.g., \"state-change\", \"note\").
Returns alist with deletion result."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char pos)
      (if (not (org-at-heading-p))
          `(("status" . "error")
            ("message" . "No heading found at position"))
        (let* ((title (org-get-heading t t t t))
               (drawer-name (cond
                             ((and (boundp 'org-log-into-drawer)
                                   (stringp org-log-into-drawer))
                              org-log-into-drawer)
                             (t "LOGBOOK")))
               (end-of-subtree (save-excursion (org-end-of-subtree t) (point)))
               (deleted nil)
               (deleted-entry-raw nil))
          ;; Find the LOGBOOK drawer
          (if (not (re-search-forward
                    (format "^[ \t]*:%s:[ \t]*$" (regexp-quote drawer-name))
                    end-of-subtree t))
              `(("status" . "error")
                ("message" . ,(format "No LOGBOOK drawer found for '%s'" title)))
            (let ((drawer-start (point))
                  (drawer-end (save-excursion
                                (re-search-forward "^[ \t]*:END:[ \t]*$" end-of-subtree t)
                                (match-beginning 0))))
              (if (not drawer-end)
                  `(("status" . "error")
                    ("message" . "Malformed LOGBOOK drawer - no :END: found"))
                ;; Search for entry matching the date
                (goto-char drawer-start)
                (forward-line 1)
                (while (and (not deleted) (< (point) drawer-end))
                  (let ((line-start (line-beginning-position))
                        (line-end (line-end-position))
                        (line (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position))))
                    ;; Check if this line is a logbook entry starting with "- "
                    (when (string-match "^[ \t]*- " line)
                      ;; Check if it contains our target date in an inactive timestamp
                      (when (string-match (concat "\\[" (regexp-quote date)) line)
                        ;; Check entry type if specified
                        (let ((is-state-change (string-match "State \"" line))
                              (is-note (string-match "Note taken on" line))
                              (should-delete t))
                          (when entry-type
                            (setq should-delete
                                  (cond
                                   ((string= entry-type "state-change") is-state-change)
                                   ((string= entry-type "note") is-note)
                                   (t t))))  ; Unknown type - delete anyway
                          (when should-delete
                            ;; Found the entry to delete
                            ;; Check for continuation lines (indented, not starting with "- " or ":")
                            (let ((entry-end line-end))
                              (save-excursion
                                (forward-line 1)
                                (while (and (< (point) drawer-end)
                                            (looking-at "^[ \t]+[^-:]"))
                                  (setq entry-end (line-end-position))
                                  (forward-line 1)))
                              ;; Delete the entry (including newline)
                              (setq deleted-entry-raw
                                    (buffer-substring-no-properties line-start (min (1+ entry-end) drawer-end)))
                              (delete-region line-start (min (1+ entry-end) drawer-end))
                              (setq deleted t)
                              ;; Update drawer-end since we deleted content
                              (setq drawer-end (- drawer-end (- (min (1+ entry-end) drawer-end) line-start)))))))))
                  (unless deleted
                    (forward-line 1)))
                (if deleted
                    (progn
                      (save-buffer)
                      (org-agenda-api--invalidate-cache)
                      `(("status" . "deleted")
                        ("title" . ,title)
                        ("date" . ,date)
                        ("deletedEntry" . ,(string-trim deleted-entry-raw))))
                  `(("status" . "not_found")
                    ("message" . ,(format "No logbook entry found for date %s%s"
                                          date
                                          (if entry-type
                                              (format " with type '%s'" entry-type)
                                            "")))))))))))))

(provide 'org-agenda-api-mutations)
;;; org-agenda-api-mutations.el ends here
