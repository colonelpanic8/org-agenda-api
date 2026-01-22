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

;; Only proceed if org-window-habit is available
(when (require 'org-window-habit nil t)

  ;;; Core Functions

  (defun org-agenda-api--window-habit-available-p ()
    "Return non-nil if org-window-habit is loaded and enabled."
    (and (featurep 'org-window-habit)
         (bound-and-true-p org-window-habit-mode)))

  (defun org-agenda-api--is-window-habit-p ()
    "Return non-nil if entry at point is an org-window-habit.
Must be called with point at an org heading."
    (and (org-agenda-api--window-habit-available-p)
         (or (org-entry-get nil (org-window-habit-property "ASSESSMENT_INTERVAL") t)
             (org-entry-get nil (org-window-habit-property "WINDOW_SPECS") t))))

  (defun org-agenda-api--get-habit-summary ()
    "Get habit summary for the entry at point.
Returns an alist suitable for JSON encoding, or nil if not a window-habit."
    (when (org-agenda-api--is-window-habit-p)
      (condition-case err
          (let* ((habit (org-window-habit-create-instance-from-heading-at-point))
                 (window-specs (oref habit window-specs))
                 (first-spec (car window-specs))
                 (iterator (org-window-habit-iterator-from-time first-spec))
                 (conforming-ratio (org-window-habit-conforming-ratio iterator))
                 (next-required (org-window-habit-get-next-required-interval habit))
                 (window (oref iterator window))
                 (start-index (oref iterator start-index))
                 (end-index (oref iterator end-index))
                 (completions-in-window (- end-index start-index))
                 (target-reps (oref first-spec target-repetitions))
                 (completion-needed-today
                  (org-window-habit-time-falls-in-assessment-interval window next-required)))
            `(("conformingRatio" . ,conforming-ratio)
              ("completionNeededToday" . ,(if completion-needed-today t :json-false))
              ("nextRequiredInterval" . ,(format-time-string "%Y-%m-%d" next-required))
              ("completionsInWindow" . ,completions-in-window)
              ("targetRepetitions" . ,target-reps)))
        (error
         (org-agenda-api--log 'warn "Failed to get habit summary: %s" (error-message-string err))
         nil))))

  (defun org-agenda-api--build-habit-graph-data (habit &optional preceding following)
    "Build semantic graph data for HABIT.
PRECEDING is number of intervals before today (default 21).
FOLLOWING is number of intervals after today (default 4).
Returns a list of alists suitable for JSON encoding."
    (setq preceding (or preceding org-window-habit-preceding-intervals))
    (setq following (or following org-window-habit-following-days))
    (let* ((now (current-time))
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
                   ;; Determine if this is past, present, or future
                   (time-type (cond
                               ((time-less-p assessment-end now) 'past)
                               ((time-less-p now assessment-start) 'future)
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

  (defun org-agenda-api--habit-status-impl (id preceding following)
    "Build habit status response for ID with PRECEDING and FOLLOWING params.
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
                       (graph (org-agenda-api--build-habit-graph-data habit preceding following))
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
  - 'following' (optional, default 4): intervals after today"
    (condition-case err
        (let* ((id (cadr (assoc "id" query)))
               (preceding (let ((p (cadr (assoc "preceding" query))))
                            (when p (string-to-number p))))
               (following (let ((f (cadr (assoc "following" query))))
                            (when f (string-to-number f)))))
          (insert
           (json-encode
            (cond
             ((not id)
              `(("status" . "error") ("message" . "Missing required 'id' parameter")))
             ((not (org-agenda-api--window-habit-available-p))
              `(("status" . "error") ("message" . "org-window-habit-mode is not enabled")))
             (t
              (org-agenda-api--habit-status-impl id preceding following))))))
      (error
       (org-agenda-api--log-error-with-backtrace "/habit-status" err)
       (insert (json-encode `(("status" . "error")
                              ("message" . ,(error-message-string err)))))))
    (org-agenda-api--track-request))

  ;; Log that the module is loaded
  (org-agenda-api--log 'info "org-window-habit integration module loaded"))

(provide 'org-agenda-api-window-habit)

;;; org-agenda-api-window-habit.el ends here
