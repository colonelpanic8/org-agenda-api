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
         (target-file (car location))
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

(provide 'org-agenda-api-mutations)
;;; org-agenda-api-mutations.el ends here
