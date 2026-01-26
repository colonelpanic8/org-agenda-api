;;; org-agenda-api-data.el --- Data extraction for org-agenda-api -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison
;; Author: Ivan Malison <IvanMalison@gmail.com>

;;; Commentary:
;; Functions for extracting data from org entries: timestamps, planning info,
;; properties, agenda traversal, and lenient heading matching.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-agenda)
(require 'org-element)
(require 'org-agenda-api-core)

;;; Timestamp Handling

(defun org-agenda-api--parse-notify-before (value)
  "Parse WILD_NOTIFIER_NOTIFY_BEFORE VALUE into a list of integers.
VALUE can be space or comma separated minutes, e.g., \"10 30 60\" or \"10,30,60\"."
  (when value
    (let ((parts (split-string value "[, \t]+" t)))
      (delq nil (mapcar (lambda (s)
                          (let ((n (string-to-number s)))
                            (when (> n 0) n)))
                        parts)))))

(defun org-agenda-api--timestamp-to-time (ts-element)
  "Convert org-element timestamp TS-ELEMENT start to Emacs time.
Returns nil if TS-ELEMENT is nil."
  (when ts-element
    (let ((year (org-element-property :year-start ts-element))
          (month (org-element-property :month-start ts-element))
          (day (org-element-property :day-start ts-element))
          (hour (or (org-element-property :hour-start ts-element) 0))
          (minute (or (org-element-property :minute-start ts-element) 0)))
      (encode-time 0 minute hour day month year))))

(defun org-agenda-api--timestamp-end-to-time (ts-element)
  "Convert org-element timestamp TS-ELEMENT end to Emacs time.
Returns nil if TS-ELEMENT is nil or has no end date."
  (when (and ts-element (org-element-property :year-end ts-element))
    (let ((year (org-element-property :year-end ts-element))
          (month (org-element-property :month-end ts-element))
          (day (org-element-property :day-end ts-element))
          (hour (or (org-element-property :hour-end ts-element) 0))
          (minute (or (org-element-property :minute-end ts-element) 0)))
      (encode-time 0 minute hour day month year))))

(defun org-agenda-api--format-timestamp (time has-time)
  "Format TIME as ISO string.
If HAS-TIME is non-nil, include time component in local timezone.
Otherwise return date-only format."
  (when time
    (if has-time
        (format-time-string "%Y-%m-%dT%H:%M:%S" time)
      (format-time-string "%Y-%m-%d" time))))

(defun org-agenda-api--format-timestamp-object (time has-time repeater)
  "Format TIME as timestamp object with date, time (optional), and repeater (optional).
Returns alist like ((date . \"2026-01-25\") (time . \"10:00\") (repeater . ...))
or nil if TIME is nil."
  (when time
    (let ((result `(("date" . ,(format-time-string "%Y-%m-%d" time)))))
      (when has-time
        (push (cons "time" (format-time-string "%H:%M" time)) result))
      (when repeater
        (push (cons "repeater" repeater) result))
      (nreverse result))))

(defun org-agenda-api--extract-date (timestamp)
  "Extract YYYY-MM-DD date portion from TIMESTAMP.
TIMESTAMP may be:
  - An alist like ((\"date\" . \"2026-01-19\") (\"time\" . \"10:00\"))
  - A string like \"2026-01-19\" or \"2026-01-19T10:00:00\"
  - nil
Returns the date string or nil if TIMESTAMP is nil."
  (when timestamp
    (cond
     ;; New format: alist with \"date\" key
     ((and (listp timestamp) (assoc "date" timestamp))
      (cdr (assoc "date" timestamp)))
     ;; Old format: string
     ((stringp timestamp)
      (substring timestamp 0 (min 10 (length timestamp))))
     ;; Unknown format
     (t nil))))

(defun org-agenda-api--extract-repeater-from-element (ts-elem)
  "Extract repeater info from timestamp element TS-ELEM.
Returns an alist with type, value, unit if repeater present, nil otherwise."
  (let ((repeater-type (org-element-property :repeater-type ts-elem))
        (repeater-value (org-element-property :repeater-value ts-elem))
        (repeater-unit (org-element-property :repeater-unit ts-elem)))
    (when (and repeater-type repeater-value repeater-unit)
      `(("type" . ,(pcase repeater-type
                     ('cumulate "+")
                     ('catch-up "++")
                     ('restart ".+")
                     (_ "+")))
        ("value" . ,repeater-value)
        ("unit" . ,(symbol-name repeater-unit))))))

(defun org-agenda-api--get-planning-info ()
  "Get scheduled and deadline info at point.
Return alist with scheduled-time, scheduled-has-time, scheduled-repeater,
scheduled-end-time, scheduled-end-has-time, deadline-time, deadline-has-time,
deadline-repeater, deadline-end-time, deadline-end-has-time.
Supports ranged timestamps like <2024-06-15>--<2024-06-20>."
  (save-excursion
    (let ((scheduled-time (org-get-scheduled-time (point)))
          (deadline-time (org-get-deadline-time (point)))
          (scheduled-has-time nil)
          (deadline-has-time nil)
          (scheduled-repeater nil)
          (deadline-repeater nil)
          (scheduled-end-time nil)
          (scheduled-end-has-time nil)
          (deadline-end-time nil)
          (deadline-end-has-time nil)
          ;; Get the headline element to access timestamp properties directly
          (headline-elem (org-element-at-point)))
      ;; Extract timestamp info from org-element
      (let ((scheduled-ts (org-element-property :scheduled headline-elem))
            (deadline-ts (org-element-property :deadline headline-elem)))
        ;; Process SCHEDULED timestamp
        (when scheduled-ts
          (setq scheduled-has-time (not (null (org-element-property :hour-start scheduled-ts))))
          (setq scheduled-repeater (org-agenda-api--extract-repeater-from-element scheduled-ts))
          ;; Check for range (:range-type is set for ranged timestamps like <date>--<date>)
          (when (org-element-property :range-type scheduled-ts)
            (setq scheduled-end-time (org-agenda-api--timestamp-end-to-time scheduled-ts))
            (setq scheduled-end-has-time (not (null (org-element-property :hour-end scheduled-ts))))))
        ;; Process DEADLINE timestamp
        (when deadline-ts
          (setq deadline-has-time (not (null (org-element-property :hour-start deadline-ts))))
          (setq deadline-repeater (org-agenda-api--extract-repeater-from-element deadline-ts))
          ;; Check for range (:range-type is set for ranged timestamps like <date>--<date>)
          (when (org-element-property :range-type deadline-ts)
            (setq deadline-end-time (org-agenda-api--timestamp-end-to-time deadline-ts))
            (setq deadline-end-has-time (not (null (org-element-property :hour-end deadline-ts)))))))
      `((scheduled-time . ,scheduled-time)
        (scheduled-has-time . ,scheduled-has-time)
        (scheduled-repeater . ,scheduled-repeater)
        (scheduled-end-time . ,scheduled-end-time)
        (scheduled-end-has-time . ,scheduled-end-has-time)
        (deadline-time . ,deadline-time)
        (deadline-has-time . ,deadline-has-time)
        (deadline-repeater . ,deadline-repeater)
        (deadline-end-time . ,deadline-end-time)
        (deadline-end-has-time . ,deadline-end-has-time)))))

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

(defun org-agenda-api--entry-has-scheduled-time-p (entry)
  "Return non-nil if ENTRY has a specific scheduled time (not just date)."
  (let ((scheduled (cdr (assoc "scheduled" entry))))
    (and scheduled
         (listp scheduled)
         (cdr (assoc "time" scheduled)))))

(defun org-agenda-api--entry-is-untimed-habit-p (entry)
  "Return non-nil if ENTRY is a window habit without a specific scheduled time."
  (and (eq (cdr (assoc "isWindowHabit" entry)) t)
       (not (org-agenda-api--entry-has-scheduled-time-p entry))))

(defun org-agenda-api--group-habits-in-agenda (entries)
  "Reorder ENTRIES to group untimed habits together at the end.
Habits with a specific scheduled time remain in their time-based position.
Untimed habits are moved to the end and sorted alphabetically by title."
  (let ((non-habits nil)
        (timed-habits nil)
        (untimed-habits nil))
    ;; Partition entries into three groups
    (dolist (entry entries)
      (cond
       ((not (eq (cdr (assoc "isWindowHabit" entry)) t))
        ;; Not a habit - keep in original order
        (push entry non-habits))
       ((org-agenda-api--entry-has-scheduled-time-p entry)
        ;; Habit with specific time - keep in original order
        (push entry timed-habits))
       (t
        ;; Untimed habit - will be grouped at end
        (push entry untimed-habits))))
    ;; Reverse to restore original order for non-habits and timed-habits
    (setq non-habits (nreverse non-habits))
    (setq timed-habits (nreverse timed-habits))
    ;; Sort untimed habits by title
    (setq untimed-habits
          (sort (nreverse untimed-habits)
                (lambda (a b)
                  (string< (or (cdr (assoc "title" a)) "")
                           (or (cdr (assoc "title" b)) "")))))
    ;; Merge: non-habits first, then timed-habits interspersed, then untimed-habits at end
    ;; Actually, we want to preserve the relative order of non-habits and timed-habits
    ;; So we need to merge them back in their original positions
    (let ((merged nil)
          (non-habit-set (make-hash-table :test 'equal))
          (timed-habit-set (make-hash-table :test 'equal)))
      ;; Build sets for quick lookup
      (dolist (e non-habits)
        (puthash (cons (cdr (assoc "file" e)) (cdr (assoc "pos" e))) t non-habit-set))
      (dolist (e timed-habits)
        (puthash (cons (cdr (assoc "file" e)) (cdr (assoc "pos" e))) t timed-habit-set))
      ;; Iterate through original entries, keeping non-habits and timed-habits in order
      (dolist (entry entries)
        (let ((key (cons (cdr (assoc "file" entry)) (cdr (assoc "pos" entry)))))
          (when (or (gethash key non-habit-set)
                    (gethash key timed-habit-set))
            (push entry merged))))
      ;; Append untimed habits at the end
      (append (nreverse merged) untimed-habits))))

;;; Property and Logbook Functions

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

(defun org-agenda-api--parse-inactive-timestamp (ts-string)
  "Parse inactive timestamp TS-STRING to ISO format.
Handles timestamps like 2026-01-21 Wed 10:30 (content from org-ts-regexp-inactive capture)."
  (when ts-string
    ;; org-ts-regexp-inactive captures: YYYY-MM-DD followed by optional day/time
    ;; e.g., "2026-01-21 Wed 10:30" or "2026-01-21 Wed"
    (let ((date (if (string-match "^\\([0-9]+-[0-9]+-[0-9]+\\)" ts-string)
                    (match-string 1 ts-string)))
          (time (if (string-match "\\([0-9]+:[0-9]+\\)" ts-string)
                    (match-string 1 ts-string))))
      (when date
        (if time
            (format "%sT%s:00" date time)
          date)))))

(defun org-agenda-api--get-logbook-entries ()
  "Get LOGBOOK entries for the entry at point.
Returns a list of alists, each containing type, timestamp, and details.
Parses state changes and notes from the LOGBOOK drawer.
Uses patterns similar to `org-habit-parse-todo' for robust parsing."
  (save-excursion
    (let ((entries nil)
          (drawer-name (cond
                        ((and (boundp 'org-log-into-drawer)
                              (stringp org-log-into-drawer))
                         org-log-into-drawer)
                        (t "LOGBOOK")))
          (end-of-subtree (save-excursion (org-end-of-subtree t) (point)))
          ;; Use org's built-in inactive timestamp regex for robust matching
          (ts-re org-ts-regexp-inactive))
      ;; Find the LOGBOOK drawer
      (when (re-search-forward
             (format "^[ \t]*:%s:[ \t]*$" (regexp-quote drawer-name))
             end-of-subtree t)
        (let ((drawer-end (save-excursion
                           (re-search-forward "^[ \t]*:END:[ \t]*$" end-of-subtree t))))
          (when drawer-end
            ;; Parse entries within the drawer
            (while (re-search-forward "^[ \t]*- " drawer-end t)
              (let ((line-start (point))
                    (line-end (line-end-position)))
                (cond
                 ;; State change: - State "NEW" from "OLD" [timestamp]
                 ;; Pattern based on org-habit-parse-todo
                 ((looking-at (concat "State \"\\([^\"]+\\)\"\\(?: from \"\\([^\"]*\\)\"\\)?[ \t]+" ts-re))
                  (let* ((new-state (match-string 1))
                         (old-state (match-string 2))
                         (timestamp-str (match-string 3))
                         (timestamp (org-agenda-api--parse-inactive-timestamp timestamp-str)))
                    (push `(("type" . "state-change")
                            ("to" . ,new-state)
                            ("from" . ,old-state)
                            ("timestamp" . ,timestamp)
                            ("raw" . ,(buffer-substring line-start line-end)))
                          entries)))
                 ;; Note: - Note taken on [timestamp]
                 ((looking-at (concat "Note taken on " ts-re))
                  (let* ((timestamp-str (match-string 1))
                         (timestamp (org-agenda-api--parse-inactive-timestamp timestamp-str))
                         ;; Get note content (may span multiple lines)
                         (note-content
                          (save-excursion
                            (forward-line 1)
                            (let ((content-lines nil))
                              (while (and (< (point) drawer-end)
                                          (looking-at "^[ \t]+\\([^ \t-]\\|$\\)"))
                                (push (string-trim (buffer-substring
                                                    (line-beginning-position)
                                                    (line-end-position)))
                                      content-lines)
                                (forward-line 1))
                              (when content-lines
                                (string-join (nreverse content-lines) "\n"))))))
                    (push `(("type" . "note")
                            ("timestamp" . ,timestamp)
                            ("content" . ,note-content)
                            ("raw" . ,(buffer-substring line-start line-end)))
                          entries)))
                 ;; Clock entry: CLOCK: [timestamp]--[timestamp] => duration
                 ((looking-at (concat "CLOCK: " ts-re "\\(?:--" ts-re "\\)?\\(?: =>.*\\)?"))
                  nil) ;; Skip clock entries for now, they're not usually needed
                 ;; Other log entry - capture as generic
                 (t
                  (push `(("type" . "other")
                          ("raw" . ,(buffer-substring line-start line-end)))
                        entries))))))))
      (nreverse entries))))

(defun org-agenda-api--format-timestamp-element (ts-elem)
  "Format org-element timestamp TS-ELEM as an alist for JSON.
Returns alist with start, end (if range), hasTime, type, and raw fields."
  (when ts-elem
    (let* ((ts-type (org-element-property :type ts-elem))
           (is-range (memq ts-type '(active-range inactive-range)))
           (has-time-start (not (null (org-element-property :hour-start ts-elem))))
           (has-time-end (not (null (org-element-property :hour-end ts-elem))))
           (start-time (org-agenda-api--timestamp-to-time ts-elem))
           (end-time (when is-range (org-agenda-api--timestamp-end-to-time ts-elem)))
           (raw (org-element-property :raw-value ts-elem))
           (type-str (pcase ts-type
                       ('active "active")
                       ('active-range "active-range")
                       ('inactive "inactive")
                       ('inactive-range "inactive-range")
                       (_ "unknown"))))
      `(("start" . ,(org-agenda-api--format-timestamp start-time has-time-start))
        ("end" . ,(when end-time (org-agenda-api--format-timestamp end-time has-time-end)))
        ("hasTime" . ,(if has-time-start t :json-false))
        ("type" . ,type-str)
        ("raw" . ,raw)))))

(defun org-agenda-api--get-entry-timestamps ()
  "Get plain timestamps from the current entry body.
Returns a list of timestamp alists, excluding SCHEDULED/DEADLINE/CLOSED.
Each alist has: start, end (if range), hasTime, type, raw."
  (save-excursion
    (let ((entry-end (save-excursion (org-end-of-subtree t t)))
          (timestamps nil))
      ;; Move past the headline
      (forward-line 1)
      ;; Skip planning line if present
      (when (looking-at org-planning-line-re)
        (forward-line 1))
      ;; Skip property drawer if present
      (when (looking-at org-property-drawer-re)
        (re-search-forward ":END:" entry-end t)
        (forward-line 1))
      ;; Now scan the body for timestamps
      (while (re-search-forward org-ts-regexp entry-end t)
        (let* ((ts-elem (org-element-context))
               (ts-type (org-element-type ts-elem)))
          ;; Only include actual timestamps (not part of SCHEDULED/DEADLINE/CLOSED)
          (when (eq ts-type 'timestamp)
            (let ((parent (org-element-property :parent ts-elem)))
              ;; Exclude if parent is a planning element
              (unless (and parent (eq (org-element-type parent) 'planning))
                (let ((formatted (org-agenda-api--format-timestamp-element ts-elem)))
                  (when formatted
                    (push formatted timestamps))))))))
      (nreverse timestamps))))

;;; Agenda Traversal Functions

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
              (scheduled-repeater (alist-get 'scheduled-repeater planning))
              (scheduled-end-time (alist-get 'scheduled-end-time planning))
              (scheduled-end-has-time (alist-get 'scheduled-end-has-time planning))
              (deadline-time (alist-get 'deadline-time planning))
              (deadline-has-time (alist-get 'deadline-has-time planning))
              (deadline-repeater (alist-get 'deadline-repeater planning))
              (deadline-end-time (alist-get 'deadline-end-time planning))
              (deadline-end-has-time (alist-get 'deadline-end-has-time planning))
              (pos (point))
              (org-id (org-entry-get (point) "ID"))
              (olpath (org-get-outline-path t))  ; include current heading
              (notify-before (org-agenda-api--parse-notify-before
                              (org-entry-get (point) "WILD_NOTIFIER_NOTIFY_BEFORE")))
              (effective-category (org-get-category))
              (all-properties (org-agenda-api--get-all-entry-properties))
              ;; Get plain timestamps from entry body
              (timestamps (org-agenda-api--get-entry-timestamps))
              ;; Habit detection - only if the window-habit module is loaded
              (is-window-habit (and (fboundp 'org-agenda-api--is-window-habit-p)
                                    (org-agenda-api--is-window-habit-p)))
              (habit-summary (when (and is-window-habit
                                        (fboundp 'org-agenda-api--get-habit-summary))
                               (org-agenda-api--get-habit-summary)))
              ;; Get logbook entries
              (logbook (org-agenda-api--get-logbook-entries)))
         ;; Return an alist directly for JSON encoding (skip org-element overhead)
         `(("todo" . ,todo)
           ("title" . ,title)
           ("tags" . ,(if tags (vconcat tags) nil))
           ("level" . ,level)
           ("scheduled" . ,(org-agenda-api--format-timestamp-object scheduled-time scheduled-has-time scheduled-repeater))
           ,@(when scheduled-end-time
               `(("scheduledEnd" . ,(org-agenda-api--format-timestamp-object scheduled-end-time scheduled-end-has-time nil))))
           ("deadline" . ,(org-agenda-api--format-timestamp-object deadline-time deadline-has-time deadline-repeater))
           ,@(when deadline-end-time
               `(("deadlineEnd" . ,(org-agenda-api--format-timestamp-object deadline-end-time deadline-end-has-time nil))))
           ,@(when timestamps
               `(("timestamps" . ,(vconcat timestamps))))
           ("file" . ,filepath)
           ("pos" . ,pos)
           ("id" . ,org-id)
           ("olpath" . ,(if olpath (vconcat olpath) nil))
           ("notifyBefore" . ,(when notify-before (vconcat notify-before)))
           ("priority" . ,priority)
           ("effectiveCategory" . ,effective-category)
           ("properties" . ,all-properties)
           ("isWindowHabit" . ,(if is-window-habit t :json-false))
           ,@(when habit-summary
               `(("habitSummary" . ,habit-summary)))
           ,@(when logbook
               `(("logbook" . ,(vconcat logbook)))))))
     "TODO={.+}"  ; MATCH: regex matches any non-empty TODO keyword (active or done)
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

(defun org-agenda-api--extract-entry-data (marker agenda-line &optional query-date)
  "Extract todo data from the org entry at MARKER.
AGENDA-LINE is the raw agenda display text for reference.
QUERY-DATE is an optional date string (YYYY-MM-DD) used to check habit completions."
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
                 (scheduled-repeater (alist-get 'scheduled-repeater planning))
                 (scheduled-end-time (alist-get 'scheduled-end-time planning))
                 (scheduled-end-has-time (alist-get 'scheduled-end-has-time planning))
                 (deadline-time (alist-get 'deadline-time planning))
                 (deadline-has-time (alist-get 'deadline-has-time planning))
                 (deadline-repeater (alist-get 'deadline-repeater planning))
                 (deadline-end-time (alist-get 'deadline-end-time planning))
                 (deadline-end-has-time (alist-get 'deadline-end-has-time planning))
                 (pos (point))
                 (filepath (buffer-file-name))
                 (org-id (org-entry-get (point) "ID"))
                 (olpath (org-get-outline-path t))
                 (priority (org-entry-get (point) "PRIORITY"))
                 (notify-before (org-agenda-api--parse-notify-before
                                 (org-entry-get (point) "WILD_NOTIFIER_NOTIFY_BEFORE")))
                 (effective-category (org-get-category))
                 (all-properties (org-agenda-api--get-all-entry-properties))
                 ;; Get plain timestamps from entry body
                 (timestamps (org-agenda-api--get-entry-timestamps))
                 ;; Extract CLOSED timestamp directly from the org entry
                 (completed-at (org-agenda-api--get-closed-timestamp))
                 ;; Habit detection - only if the window-habit module is loaded
                 (is-window-habit (and (fboundp 'org-agenda-api--is-window-habit-p)
                                       (org-agenda-api--is-window-habit-p)))
                 (habit-summary (when (and is-window-habit
                                           (fboundp 'org-agenda-api--get-habit-summary))
                                  (org-agenda-api--get-habit-summary)))
                 ;; Check if habit was completed on the query date
                 (habit-completed-on-query-date
                  (when (and is-window-habit
                             query-date
                             (fboundp 'org-agenda-api--habit-completed-on-date-p))
                    (org-agenda-api--habit-completed-on-date-p query-date))))
            `(("todo" . ,todo)
              ("title" . ,title)
              ("tags" . ,(if tags (vconcat tags) nil))
              ("level" . ,level)
              ("scheduled" . ,(org-agenda-api--format-timestamp-object scheduled-time scheduled-has-time scheduled-repeater))
              ,@(when scheduled-end-time
                  `(("scheduledEnd" . ,(org-agenda-api--format-timestamp-object scheduled-end-time scheduled-end-has-time nil))))
              ("deadline" . ,(org-agenda-api--format-timestamp-object deadline-time deadline-has-time deadline-repeater))
              ,@(when deadline-end-time
                  `(("deadlineEnd" . ,(org-agenda-api--format-timestamp-object deadline-end-time deadline-end-has-time nil))))
              ,@(when timestamps
                  `(("timestamps" . ,(vconcat timestamps))))
              ("file" . ,filepath)
              ("pos" . ,pos)
              ("id" . ,org-id)
              ("olpath" . ,(if olpath (vconcat olpath) nil))
              ("priority" . ,priority)
              ("notifyBefore" . ,(when notify-before (vconcat notify-before)))
              ("effectiveCategory" . ,effective-category)
              ("agendaLine" . ,(substring-no-properties agenda-line))
              ("properties" . ,all-properties)
              ("completedAt" . ,completed-at)
              ("isWindowHabit" . ,(if is-window-habit t :json-false))
              ,@(when habit-summary
                  `(("habitSummary" . ,habit-summary)))
              ,@(when habit-completed-on-query-date
                  `(("habitCompletedOnQueryDate" . t))))))))))

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
                    (let ((entry-data (org-agenda-api--extract-entry-data marker line start-date)))
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
                                              (cdr (assoc "completedAt" entry))))
                          (habit-completed (cdr (assoc "habitCompletedOnQueryDate" entry))))
                      ;; Keep entries with:
                      ;; - scheduled date <= start-date (includes overdue)
                      ;; - deadline date <= start-date
                      ;; - completed on the query date (via CLOSED timestamp)
                      ;; - habit completed on the query date (via LOGBOOK done-times)
                      ;; - no scheduled/deadline ONLY when not in log mode
                      ;;   (When include-completed is true, log mode shows state change entries
                      ;;   that have no scheduled/deadline - these should only be kept if they
                      ;;   have a completedAt matching the query date)
                      (or (and (null scheduled-date) (null deadline-date) (not include-completed))
                          (and scheduled-date (not (string-greaterp scheduled-date start-date)))
                          (and deadline-date (not (string-greaterp deadline-date start-date)))
                          (and completed-at-date (string= completed-at-date start-date))
                          habit-completed)))
                  all-entries)
               ;; Default: only items scheduled for the exact query date
               (cl-remove-if-not
                (lambda (entry)
                  (let ((scheduled-date (org-agenda-api--extract-date
                                         (cdr (assoc "scheduled" entry))))
                        (deadline-date (org-agenda-api--extract-date
                                        (cdr (assoc "deadline" entry))))
                        (completed-at-date (org-agenda-api--extract-date
                                            (cdr (assoc "completedAt" entry))))
                        (habit-completed (cdr (assoc "habitCompletedOnQueryDate" entry))))
                    ;; Keep entries that have either:
                    ;; - scheduled date matching start-date
                    ;; - deadline date matching start-date
                    ;; - completed at date matching start-date (log entries)
                    ;; - habit completed on the query date (via LOGBOOK done-times)
                    ;; - no scheduled/deadline (time grid items) ONLY when not in log mode
                    ;;   (When include-completed is true, log mode shows state change entries
                    ;;   that have no scheduled/deadline - these should only be kept if they
                    ;;   have a completedAt matching the query date)
                    (or (and (null scheduled-date) (null deadline-date) (not include-completed))
                        (and scheduled-date (string= scheduled-date start-date))
                        (and deadline-date (string= deadline-date start-date))
                        (and completed-at-date (string= completed-at-date start-date))
                        habit-completed)))
                all-entries))))
        ;; When include-completed is requested, also fetch habits that were
        ;; completed on the query date but might not appear in the agenda
        ;; (because habits reschedule to future dates when completed)
        (when (and include-completed
                   (fboundp 'org-agenda-api--get-habits-completed-on-date))
          (org-agenda-api--log 'debug "run-agenda: Checking for habits completed on %s" start-date)
          (let ((habit-locations (org-agenda-api--get-habits-completed-on-date start-date)))
            (org-agenda-api--log 'debug "run-agenda: Found %d habit locations: %S"
                                 (length habit-locations) habit-locations)
            (dolist (loc habit-locations)
              (let* ((file (car loc))
                     (pos (cdr loc))
                     (already-present
                      (cl-some (lambda (entry)
                                 (and (string= (cdr (assoc "file" entry)) file)
                                      (= (cdr (assoc "pos" entry)) pos)))
                               filtered-entries)))
                (org-agenda-api--log 'debug "run-agenda: Habit at %s:%d already-present=%s"
                                     file pos already-present)
                (unless already-present
                  (with-current-buffer (find-file-noselect file)
                    (save-excursion
                      (goto-char pos)
                      (when (org-at-heading-p)
                        (let ((entry-data (org-agenda-api--extract-habit-entry-data pos file start-date)))
                          (org-agenda-api--log 'debug "run-agenda: Extracted habit entry: %S"
                                               (when entry-data (cdr (assoc "title" entry-data))))
                          (when entry-data
                            (setq filtered-entries (cons entry-data filtered-entries))))))))))))
        ;; Deduplicate entries - when an item has both SCHEDULED and DEADLINE
        ;; on the same day, org-agenda shows it twice. Keep only unique entries
        ;; based on (file, pos).
        ;; Then group untimed habits together at the end.
        (org-agenda-api--group-habits-in-agenda
         (org-agenda-api--deduplicate-entries filtered-entries))))))

(defun org-agenda-api--extract-habit-entry-data (pos file query-date)
  "Extract entry data for a habit at POS in FILE.
QUERY-DATE is used to mark habitCompletedOnQueryDate.
This is similar to `org-agenda-api--extract-entry-data' but works directly
from the org buffer rather than an agenda line."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char pos)
      (when (org-at-heading-p)
        (let* ((todo (org-get-todo-state))
               (title (org-get-heading t t t t))
               (tags (org-get-tags))
               (level (org-current-level))
               (planning (org-agenda-api--get-planning-info))
               (scheduled-time (alist-get 'scheduled-time planning))
               (scheduled-has-time (alist-get 'scheduled-has-time planning))
               (scheduled-repeater (alist-get 'scheduled-repeater planning))
               (deadline-time (alist-get 'deadline-time planning))
               (deadline-has-time (alist-get 'deadline-has-time planning))
               (deadline-repeater (alist-get 'deadline-repeater planning))
               (org-id (org-entry-get (point) "ID"))
               (olpath (org-get-outline-path t))
               (priority (org-entry-get (point) "PRIORITY"))
               (notify-before (org-agenda-api--parse-notify-before
                               (org-entry-get (point) "WILD_NOTIFIER_NOTIFY_BEFORE")))
               (effective-category (org-get-category))
               (all-properties (org-agenda-api--get-all-entry-properties))
               ;; Habit detection
               (is-window-habit (and (fboundp 'org-agenda-api--is-window-habit-p)
                                     (org-agenda-api--is-window-habit-p)))
               (habit-summary (when (and is-window-habit
                                         (fboundp 'org-agenda-api--get-habit-summary))
                                (org-agenda-api--get-habit-summary)))
               ;; Check if habit was completed on the query date
               (habit-completed-on-query-date
                (when (and is-window-habit
                           query-date
                           (fboundp 'org-agenda-api--habit-completed-on-date-p))
                  (org-agenda-api--habit-completed-on-date-p query-date))))
          `(("todo" . ,todo)
            ("title" . ,title)
            ("tags" . ,(if tags (vconcat tags) nil))
            ("level" . ,level)
            ("scheduled" . ,(org-agenda-api--format-timestamp-object scheduled-time scheduled-has-time scheduled-repeater))
            ("deadline" . ,(org-agenda-api--format-timestamp-object deadline-time deadline-has-time deadline-repeater))
            ("file" . ,file)
            ("pos" . ,pos)
            ("id" . ,org-id)
            ("olpath" . ,(if olpath (vconcat olpath) nil))
            ("priority" . ,priority)
            ("notifyBefore" . ,(when notify-before (vconcat notify-before)))
            ("effectiveCategory" . ,effective-category)
            ("properties" . ,all-properties)
            ("isWindowHabit" . ,(if is-window-habit t :json-false))
            ,@(when habit-summary
                `(("habitSummary" . ,habit-summary)))
            ,@(when habit-completed-on-query-date
                `(("habitCompletedOnQueryDate" . t)))))))))

;;; Custom View Functions

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

;;; Lenient Heading Matching

(defun org-agenda-api--normalize-string (s)
  "Normalize string S for lenient comparison.
Trims whitespace, collapses multiple spaces, and normalizes unicode."
  (when s
    (let* ((trimmed (string-trim s))
           ;; Collapse multiple whitespace into single space
           (collapsed (replace-regexp-in-string "[ \t\n\r]+" " " trimmed)))
      ;; Normalize unicode if ucs-normalize is available
      (if (fboundp 'ucs-normalize-NFC-string)
          (ucs-normalize-NFC-string collapsed)
        collapsed))))

(defun org-agenda-api--string-match-lenient (s1 s2)
  "Compare S1 and S2 leniently after normalization.
Returns t if normalized versions are equal."
  (when (and s1 s2)
    (string= (org-agenda-api--normalize-string s1)
             (org-agenda-api--normalize-string s2))))

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
Uses lenient matching as fallback if strict match fails.
Returns (file . pos) cons or nil if not found."
  (when (and file pos (file-exists-p file))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char pos)
        (when (org-at-heading-p)
          (let ((heading (org-get-heading t t t t)))
            ;; Try strict match first, then lenient
            (when (or (not title)
                      (string= heading title)
                      (org-agenda-api--string-match-lenient heading title))
              (cons file pos))))))))

(defun org-agenda-api--find-todo-by-file-title (file title &optional lenient)
  "Find a TODO entry by FILE and TITLE only.
Searches the file for a heading matching TITLE.
If LENIENT is non-nil, uses lenient matching (whitespace/unicode normalized).
Returns (file . pos) cons or nil if not found."
  (when (and file title (file-exists-p file))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-min))
        (let ((found nil)
              (match-fn (if lenient
                            #'org-agenda-api--string-match-lenient
                          #'string=)))
          (while (and (not found) (re-search-forward org-heading-regexp nil t))
            (when (org-at-heading-p)
              (let ((heading (org-get-heading t t t t)))
                (when (funcall match-fn heading title)
                  (setq found (cons file (line-beginning-position)))))))
          found)))))

(defun org-agenda-api--find-todo-by-title (title &optional lenient)
  "Find a TODO entry by TITLE across all agenda files.
Searches all org-agenda-files for a heading matching TITLE.
If LENIENT is non-nil, uses lenient matching (whitespace/unicode normalized).
Returns (file . pos) cons or nil if not found."
  (when title
    (let ((found nil))
      (dolist (file org-agenda-files)
        (when (and (not found) (file-exists-p file))
          (setq found (org-agenda-api--find-todo-by-file-title file title lenient))))
      found)))

;;; Date/Time Parsing Utilities

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

(defun org-agenda-api--get-field (key obj)
  "Get field KEY from OBJ, which can be a hash-table or alist.
Returns nil if KEY is not found or OBJ is nil."
  (when obj
    (if (hash-table-p obj)
        (gethash key obj)
      (cdr (assoc key obj)))))

(defun org-agenda-api--format-repeater (repeater)
  "Format REPEATER as org repeater string.
REPEATER can be a hash-table or alist with keys \"type\", \"value\", and \"unit\".
Returns a string like \"+1w\" or \"++2d\", or nil if REPEATER is invalid."
  (when (and repeater (not (eq repeater :json-null)))
    (let ((type (org-agenda-api--get-field "type" repeater))
          (value (org-agenda-api--get-field "value" repeater))
          (unit (org-agenda-api--get-field "unit" repeater)))
      (when (and type value unit)
        (format "%s%d%s" type value unit)))))

(defun org-agenda-api--format-org-timestamp-with-repeater (time has-time repeater)
  "Format TIME as an org timestamp string, optionally with REPEATER.
If HAS-TIME is non-nil, include the time component.
REPEATER should be an alist with keys \"type\", \"value\", and \"unit\"."
  (let ((repeater-str (org-agenda-api--format-repeater repeater)))
    (if has-time
        (if repeater-str
            (format-time-string (concat "<%Y-%m-%d %a %H:%M " repeater-str ">") time)
          (format-time-string "<%Y-%m-%d %a %H:%M>" time))
      (if repeater-str
          (format-time-string (concat "<%Y-%m-%d %a " repeater-str ">") time)
        (format-time-string "<%Y-%m-%d %a>" time)))))

(defun org-agenda-api--timestamp-to-org (timestamp)
  "Convert TIMESTAMP object to org timestamp string.
TIMESTAMP can be:
  - A string like \"2026-01-25\" or \"2026-01-25T10:00:00\" (legacy format)
  - A hash-table or alist with keys \"date\" (required),
    \"time\" (optional), and \"repeater\" (optional)
Returns org timestamp like <2026-01-25 Sat 10:00 +1w>."
  (when (and timestamp (not (eq timestamp :json-null)))
    (cond
     ;; Handle string format (legacy): "2026-01-25" or "2026-01-25T10:00:00"
     ((stringp timestamp)
      (let* ((has-time (org-agenda-api--datetime-has-time-p timestamp))
             (parsed-time (org-agenda-api--parse-datetime timestamp)))
        (when parsed-time
          (org-agenda-api--format-org-timestamp-with-repeater parsed-time has-time nil))))
     ;; Handle object format: {"date": "2026-01-25", "time": "10:00", "repeater": {...}}
     (t
      (let* ((date-str (org-agenda-api--get-field "date" timestamp))
             (time-str (let ((time-val (org-agenda-api--get-field "time" timestamp)))
                         (unless (eq time-val :json-null) time-val)))
             (repeater (let ((repeater-val (org-agenda-api--get-field "repeater" timestamp)))
                         (unless (eq repeater-val :json-null) repeater-val)))
             (has-time (and time-str (not (string-empty-p time-str))))
             (datetime-str (if has-time
                               (concat date-str " " time-str)
                             date-str))
             (parsed-time (org-agenda-api--parse-datetime datetime-str)))
        (when parsed-time
          (org-agenda-api--format-org-timestamp-with-repeater parsed-time has-time repeater)))))))

(defun org-agenda-api--parse-org-timestamp-to-object (ts-string)
  "Parse org timestamp TS-STRING to timestamp object.
Returns alist with \"date\", \"time\" (if present), and \"repeater\" (if present).
Example: <2026-01-25 Sat 10:00 +1w> -> ((date . \"2026-01-25\") (time . \"10:00\") (repeater . ...))"
  (when (and ts-string (not (string-empty-p ts-string)))
    (let ((result nil))
      ;; Extract date (YYYY-MM-DD)
      (when (string-match "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" ts-string)
        (push (cons "date" (match-string 1 ts-string)) result))
      ;; Extract time (HH:MM) if present
      (when (string-match "\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)" ts-string)
        (push (cons "time" (match-string 1 ts-string)) result))
      ;; Extract repeater if present (+1w, ++2d, .+1m)
      (when (string-match "\\(\\.?\\+\\+?\\)\\([0-9]+\\)\\([dwmy]\\)" ts-string)
        (let ((type (match-string 1 ts-string))
              (value (string-to-number (match-string 2 ts-string)))
              (unit (match-string 3 ts-string)))
          (push (cons "repeater" `(("type" . ,type)
                                   ("value" . ,value)
                                   ("unit" . ,unit)))
                result)))
      (when result
        (nreverse result)))))

;;; TODO State and Filter Functions

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

(provide 'org-agenda-api-data)
;;; org-agenda-api-data.el ends here
