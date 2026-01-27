;;; org-agenda-api-window-habit.el --- org-window-habit integration for org-agenda-api -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Ivan Malison

;; Author: Ivan Malison <ivanmalison@gmail.com>
;; URL: https://github.com/colonelpanic8/org-agenda-api

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; This module provides optional org-window-habit integration for org-agenda-api.
;; When loaded and org-window-habit-mode is enabled, it provides:
;; - /habit-config endpoint for configuration colors and settings
;; - /habit-status endpoint for detailed habit status with graph data
;; - Habit summary data augmentation for /get-all-todos and /agenda endpoints

;;; Code:

(require 'org-agenda-api-core)
(require 'simple-httpd)  ; For defservlet macro

;; Only proceed if org-window-habit is available
(when (require 'org-window-habit nil t)

  ;;; Core Functions

  (defun org-agenda-api--window-habit-available-p ()
    "Return non-nil if org-window-habit is loaded and enabled."
    (and (featurep 'org-window-habit)
         (bound-and-true-p org-window-habit-mode)))

  (defun org-agenda-api--is-window-habit-p ()
    "Return non-nil if entry at point is an org-window-habit.
Must be called with point at an org heading.
Delegates to `org-window-habit-entry-p' from the org-window-habit library."
    (and (org-agenda-api--window-habit-available-p)
         (org-window-habit-entry-p)))

  (defun org-agenda-api--habit-completed-on-date-p (date-string)
    "Return non-nil if the habit at point was completed on DATE-STRING.
DATE-STRING should be in YYYY-MM-DD format.
Must be called with point at an org heading that is a window-habit."
    (when (org-agenda-api--is-window-habit-p)
      (condition-case err
          (let* ((habit (org-window-habit-create-instance-from-heading-at-point))
                 (done-times (oref habit done-times)))
            (org-agenda-api--log 'debug "habit-completed-on-date-p: title=%s date=%s done-times=%S"
                                 (org-get-heading t t t t) date-string
                                 (mapcar (lambda (tm) (format-time-string "%Y-%m-%d" tm)) done-times))
            ;; Check if any done-time matches the date
            (cl-some (lambda (time)
                       (string= (format-time-string "%Y-%m-%d" time) date-string))
                     done-times))
        (error
         (org-agenda-api--log 'debug "habit-completed-on-date-p error: %S" err)
         nil))))

  (defun org-agenda-api--get-habits-completed-on-date (date-string)
    "Get all habits that were completed on DATE-STRING.
DATE-STRING should be in YYYY-MM-DD format.
Returns a list of (file . pos) cons cells for each matching habit."
    (org-agenda-api--log 'debug "get-habits-completed-on-date: looking for date=%s in %d files"
                         date-string (length org-agenda-files))
    (let ((results nil))
      (dolist (file org-agenda-files)
        (org-agenda-api--log 'debug "get-habits-completed-on-date: checking file=%s exists=%s"
                             file (file-exists-p file))
        (when (file-exists-p file)
          (let ((buf (find-file-noselect file)))
            (with-current-buffer buf
              ;; Revert buffer if file changed on disk to get latest logbook entries
              (when (and (buffer-file-name)
                         (file-exists-p (buffer-file-name))
                         (not (verify-visited-file-modtime buf)))
                (org-agenda-api--log 'debug "get-habits-completed-on-date: reverting buffer for %s" file)
                (revert-buffer t t t))
              (save-excursion
                (goto-char (point-min))
                (let ((heading-count 0)
                      (habit-count 0))
                  (while (re-search-forward org-heading-regexp nil t)
                    (cl-incf heading-count)
                    (when (org-at-heading-p)
                      (let ((title (org-get-heading t t t t))
                            (is-habit (org-agenda-api--is-window-habit-p)))
                        (when is-habit
                          (cl-incf habit-count)
                          (org-agenda-api--log 'debug "get-habits-completed-on-date: found habit '%s'" title)
                          (when (org-agenda-api--habit-completed-on-date-p date-string)
                            (org-agenda-api--log 'debug "get-habits-completed-on-date: habit '%s' completed on %s" title date-string)
                            (push (cons file (line-beginning-position)) results))))))
                  (org-agenda-api--log 'debug "get-habits-completed-on-date: file=%s headings=%d habits=%d"
                                       file heading-count habit-count)))))))
      (org-agenda-api--log 'debug "get-habits-completed-on-date: found %d results" (length results))
      (nreverse results)))

  (defun org-agenda-api--format-window-spec-status (spec-status)
    "Format a single window spec status alist for JSON output.
Converts time values to ISO strings and plist to alist."
    (let ((duration (cdr (assoc "duration" spec-status)))
          (window-start (cdr (assoc "windowStart" spec-status)))
          (window-end (cdr (assoc "windowEnd" spec-status))))
      `(("conformingRatio" . ,(cdr (assoc "conformingRatio" spec-status)))
        ("completionsInWindow" . ,(cdr (assoc "completionsInWindow" spec-status)))
        ("targetRepetitions" . ,(cdr (assoc "targetRepetitions" spec-status)))
        ("duration" . ,(org-agenda-api--plist-to-alist duration))
        ("conformingValue" . ,(cdr (assoc "conformingValue" spec-status)))
        ("windowStart" . ,(format-time-string "%Y-%m-%dT%H:%M:%S" window-start))
        ("windowEnd" . ,(format-time-string "%Y-%m-%dT%H:%M:%S" window-end)))))

  (defun org-agenda-api--get-habit-summary ()
    "Get habit summary for the entry at point.
Returns an alist suitable for JSON encoding, or nil if not a window-habit."
    (when (org-agenda-api--is-window-habit-p)
      (condition-case err
          (let* ((habit (org-window-habit-create-instance-from-heading-at-point))
                 (next-required (org-window-habit-get-next-required-interval habit))
                 ;; Get per-window-spec conforming data using new function
                 (specs-status (org-window-habit-get-window-specs-status habit))
                 (window-specs-status (cdr (assoc "windowSpecsStatus" specs-status)))
                 (aggregated-ratio (cdr (assoc "aggregatedConformingRatio" specs-status)))
                 ;; Format each window spec status for JSON
                 (formatted-specs (vconcat
                                   (mapcar #'org-agenda-api--format-window-spec-status
                                           window-specs-status)))
                 ;; Get first spec's window for completion-needed-today check
                 (first-spec (car (oref habit window-specs)))
                 (iterator (org-window-habit-iterator-from-time first-spec))
                 (window (oref iterator window))
                 (completion-needed-today
                  (org-window-habit-time-falls-in-assessment-interval window next-required)))
            `(("conformingRatio" . ,aggregated-ratio)  ; backwards compatibility
              ("aggregatedConformingRatio" . ,aggregated-ratio)
              ("windowSpecsStatus" . ,formatted-specs)
              ("completionNeededToday" . ,(if completion-needed-today t :json-false))
              ("nextRequiredInterval" . ,(format-time-string "%Y-%m-%d" next-required))))
        (error
         (org-agenda-api--log 'warn "Failed to get habit summary: %s" (error-message-string err))
         nil))))

  (defun org-agenda-api--build-habit-graph-data (habit &optional preceding following reference-time)
    "Build semantic graph data for HABIT.
PRECEDING is number of intervals before today (default 21).
FOLLOWING is number of intervals after today (default 4).
REFERENCE-TIME is the time to use as \"now\" (default current-time).
Returns a list of alists suitable for JSON encoding."
    (setq preceding (or preceding org-window-habit-preceding-intervals))
    (setq following (or following org-window-habit-following-days))
    (let* ((now (or reference-time (current-time)))
           (today-day (time-to-days now))
           (window-specs (oref habit window-specs))
           (assessment-interval (oref habit assessment-interval))
           (assessment-decrement (org-window-habit-negate-plist assessment-interval))
           (start-time (oref habit start-time))
           (max-reps (oref habit max-repetitions-per-interval))
           (result nil))
      ;; Calculate start point by going back `preceding` intervals
      (let* ((target-start (org-window-habit-normalize-time-to-duration now assessment-interval)))
        (dotimes (_ preceding)
          (let ((new-time (org-window-habit-keyed-duration-add-plist target-start assessment-decrement)))
            (when (time-less-p start-time new-time)
              (setq target-start new-time))))
        ;; Build iterators starting at target-start
        (let ((iterators (mapcar (lambda (spec)
                                   (org-window-habit-iterator-from-time spec target-start))
                                 window-specs))
              (intervals-processed 0)
              (total-intervals (+ preceding following 1)))
          ;; Process each interval
          (while (< intervals-processed total-intervals)
            (let* ((window (oref (car iterators) window))
                   (assessment-start (oref window assessment-start-time))
                   (assessment-end (oref window assessment-end-time))
                   ;; Determine if this is past, present, or future based on org-today
                   (assessment-day (time-to-days assessment-start))
                   (time-type (cond
                               ((< assessment-day today-day) 'past)
                               ((> assessment-day today-day) 'future)
                               (t 'present)))
                   ;; Get assessments with and without completion
                   (assess-data (org-window-habit-assess-interval-with-and-without-completions
                                 habit iterators
                                 (lambda (x) (if (eq time-type 'present) max-reps x))))
                   (no-completion-val (nth 2 assess-data))
                   (with-completion-val (nth 3 assess-data))
                   (completion-count (nth 4 assess-data))
                   (next-required (org-window-habit-get-next-required-interval habit))
                   (completion-expected (org-window-habit-time-falls-in-assessment-interval
                                         window next-required)))
              (push `(("date" . ,(format-time-string "%Y-%m-%d" assessment-start))
                      ("assessmentStart" . ,(format-time-string "%Y-%m-%dT%H:%M:%S" assessment-start))
                      ("assessmentEnd" . ,(format-time-string "%Y-%m-%dT%H:%M:%S" assessment-end))
                      ("conformingRatioWithout" . ,no-completion-val)
                      ("conformingRatioWith" . ,with-completion-val)
                      ("completionCount" . ,completion-count)
                      ("status" . ,(symbol-name time-type))
                      ("completionExpectedToday" . ,(if completion-expected t :json-false)))
                    result)
              ;; Advance all iterators
              (dolist (iter iterators)
                (org-window-habit-advance iter))
              (cl-incf intervals-processed)))))
      (nreverse result)))

  ;;; Endpoint Implementations

  (defun org-agenda-api--habit-status-impl (id preceding following &optional reference-time)
    "Build habit status response for ID with PRECEDING and FOLLOWING params.
REFERENCE-TIME is the time to use as \"today\" (default current-time).
Returns a JSON-encodable alist."
    (let ((location (org-id-find id)))
      (if (not location)
          `(("status" . "error") ("message" . "Entry not found"))
        (let ((file (car location))
              (pos (cdr location)))
          (with-current-buffer (find-file-noselect file)
            (save-excursion
              (goto-char pos)
              (if (not (org-agenda-api--is-window-habit-p))
                  `(("status" . "error") ("message" . "Entry is not an org-window-habit"))
                (let* ((habit (org-window-habit-create-instance-from-heading-at-point))
                       (title (org-get-heading t t t t))
                       (done-times (oref habit done-times))
                       (window-specs (oref habit window-specs))
                       (graph (org-agenda-api--build-habit-graph-data habit preceding following reference-time))
                       (summary (org-agenda-api--get-habit-summary)))
                  `(("status" . "ok")
                    ("id" . ,id)
                    ("title" . ,title)
                    ("habit" . (("assessmentInterval" . ,(org-agenda-api--plist-to-alist
                                                          (oref habit assessment-interval)))
                                ("rescheduleInterval" . ,(org-agenda-api--plist-to-alist
                                                          (oref habit reschedule-interval)))
                                ("rescheduleThreshold" . ,(oref habit reschedule-threshold))
                                ("maxRepetitionsPerInterval" . ,(oref habit max-repetitions-per-interval))
                                ("startTime" . ,(format-time-string "%Y-%m-%dT%H:%M:%S"
                                                                    (oref habit start-time)))
                                ("windowSpecs" . ,(vconcat
                                                   (mapcar
                                                    (lambda (spec)
                                                      `(("duration" . ,(org-agenda-api--plist-to-alist
                                                                        (oref spec duration-plist)))
                                                        ("targetRepetitions" . ,(oref spec target-repetitions))
                                                        ("conformingValue" . ,(oref spec conforming-value))))
                                                    window-specs)))))
                    ("currentState" . ,summary)
                    ("doneTimes" . ,(vconcat
                                     (mapcar (lambda (time)
                                               (format-time-string "%Y-%m-%dT%H:%M:%S" time))
                                             done-times)))
                    ("graph" . ,(vconcat graph)))))))))))

  ;;; Helper Functions

  (defun org-agenda-api--get-habit-config ()
    "Return habit config data as an alist suitable for JSON encoding."
    (let ((enabled (and (boundp 'org-window-habit-mode) org-window-habit-mode)))
      (if (not enabled)
          `(("status" . "ok")
            ("enabled" . :json-false))
        `(("status" . "ok")
          ("enabled" . t)
          ("colors" . (("conforming" . ,org-window-habit-conforming-color)
                       ("notConforming" . ,org-window-habit-not-conforming-color)
                       ("requiredCompletionForeground" . ,org-window-habit-required-completion-foreground-color)
                       ("nonRequiredCompletionForeground" . ,org-window-habit-non-required-completion-foreground-color)
                       ("requiredCompletionTodayForeground" . ,org-window-habit-required-completion-today-foreground-color)))
          ("display" . (("precedingIntervals" . ,org-window-habit-preceding-intervals)
                        ("followingDays" . ,org-window-habit-following-days)
                        ("completionNeededTodayGlyph" . ,(char-to-string org-window-habit-completion-needed-today-glyph))
                        ("completedGlyph" . ,(char-to-string org-window-habit-completed-glyph))))
          ("behavior" . (("repeatToDeadline" . ,(if org-window-habit-repeat-to-deadline t :json-false))
                         ("repeatToScheduled" . ,(if org-window-habit-repeat-to-scheduled t :json-false))
                         ("nonConformingScale" . ,org-window-habit-non-conforming-scale)))))))

  ;;; HTTP Endpoints

  (defservlet habit-config application/json ()
    "Endpoint: Return org-window-habit configuration including colors and settings."
    (insert (json-encode (org-agenda-api--get-habit-config)))
    (org-agenda-api--track-request))

  (defservlet habit-status application/json (_path query)
    "Endpoint: Return detailed habit status including graph data.
Accepts query params:
  - 'id' (required): org-id of the habit entry
  - 'preceding' (optional, default 21): intervals before today
  - 'following' (optional, default 4): intervals after today
  - 'date' (optional): reference date as YYYY-MM-DD (default: today)"
    (condition-case err
        (let* ((id (cadr (assoc "id" query)))
               (preceding (let ((p (cadr (assoc "preceding" query))))
                            (when p (string-to-number p))))
               (following (let ((f (cadr (assoc "following" query))))
                            (when f (string-to-number f))))
               (date-str (cadr (assoc "date" query)))
               (reference-time (when date-str
                                 (org-agenda-api--parse-datetime date-str))))
          (insert
           (json-encode
            (cond
             ((not id)
              `(("status" . "error") ("message" . "Missing required 'id' parameter")))
             ((not (org-agenda-api--window-habit-available-p))
              `(("status" . "error") ("message" . "org-window-habit-mode is not enabled")))
             (t
              (org-agenda-api--habit-status-impl id preceding following reference-time))))))
      (error
       (org-agenda-api--log-error-with-backtrace "/habit-status" err)
       (insert (json-encode `(("status" . "error")
                              ("message" . ,(error-message-string err)))))))
    (org-agenda-api--track-request))

  (defun org-agenda-api--find-all-habits ()
    "Find all org-window-habit entries in agenda files.
Returns a list of (id . title) cons cells for each habit found."
    (let ((results nil))
      (dolist (file org-agenda-files)
        (when (file-exists-p file)
          (with-current-buffer (find-file-noselect file)
            (save-excursion
              (goto-char (point-min))
              (while (re-search-forward org-heading-regexp nil t)
                (when (and (org-at-heading-p)
                           (org-agenda-api--is-window-habit-p))
                  (let ((id (org-id-get))
                        (title (org-get-heading t t t t)))
                    (when id
                      (push (cons id title) results)))))))))
      (nreverse results)))

  (defun org-agenda-api--all-habit-statuses-impl (preceding following &optional reference-time)
    "Build all habit statuses response with PRECEDING and FOLLOWING params.
REFERENCE-TIME is the time to use as \"today\" (default current-time).
Returns a JSON-encodable alist with status for all habits."
    (let ((habits (org-agenda-api--find-all-habits))
          (habit-results nil))
      (dolist (habit-entry habits)
        (let* ((id (car habit-entry))
               (result (condition-case err
                           (org-agenda-api--habit-status-impl id preceding following reference-time)
                         (error
                          `(("id" . ,id)
                            ("error" . ,(error-message-string err)))))))
          ;; Only include if we got data (status ok) or error
          (push result habit-results)))
      `(("status" . "ok")
        ("habits" . ,(vconcat (nreverse habit-results))))))

  (defservlet all-habit-statuses application/json (_path query)
    "Endpoint: Return detailed status for all habits.
Accepts query params:
  - 'preceding' (optional, default 21): intervals before today
  - 'following' (optional, default 4): intervals after today
  - 'date' (optional): reference date as YYYY-MM-DD (default: today)"
    (condition-case err
        (let* ((preceding (let ((p (cadr (assoc "preceding" query))))
                            (when p (string-to-number p))))
               (following (let ((f (cadr (assoc "following" query))))
                            (when f (string-to-number f))))
               (date-str (cadr (assoc "date" query)))
               (reference-time (when date-str
                                 (org-agenda-api--parse-datetime date-str))))
          (insert
           (json-encode
            (if (not (org-agenda-api--window-habit-available-p))
                `(("status" . "error") ("message" . "org-window-habit-mode is not enabled"))
              (org-agenda-api--all-habit-statuses-impl preceding following reference-time)))))
      (error
       (org-agenda-api--log-error-with-backtrace "/all-habit-statuses" err)
       (insert (json-encode `(("status" . "error")
                              ("message" . ,(error-message-string err)))))))
    (org-agenda-api--track-request))

  ;; Log that the module is loaded
  (org-agenda-api--log 'info "org-window-habit integration module loaded"))

(provide 'org-agenda-api-window-habit)

;;; org-agenda-api-window-habit.el ends here
