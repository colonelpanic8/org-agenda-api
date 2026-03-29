;;; org-agenda-api-endpoints.el --- HTTP endpoints for org-agenda-api -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison
;; Author: Ivan Malison <IvanMalison@gmail.com>

;;; Commentary:
;; HTTP endpoint definitions (defservlets) for the API.

;;; Code:

(require 'json)
(require 'simple-httpd)
(require 'org-agenda-api-core)
(require 'org-agenda-api-data)
(require 'org-agenda-api-capture)
(require 'org-agenda-api-mutations)

;;; Query Endpoints

(defservlet get-all-todos application/json (_path query)
  "Endpoint: Return all TODO items from agenda files as JSON.
Response is wrapped with notification defaults.
Accepts optional query params:
  - 'refresh' (true/1) to git pull repos first
  - 'include_archives' (true/1) to include archive files/trees."
  (let* ((refresh-param (cadr (assoc "refresh" query)))
         (include-archives-param (cadr (assoc "include_archives" query)))
         (include-archives (org-agenda-api--include-archives-p include-archives-param))
         (git-results (when (member refresh-param '("true" "1"))
                        (org-agenda-api--git-refresh-all)))
         (response
          (org-agenda-api--with-archives include-archives
            (let* ((todos (if include-archives
                              (org-agenda-api--get-agenda-todos-from-files org-agenda-files)
                            (org-agenda-api--get-agenda-todos)))
                   (defaults `(("notifyBefore" . ,(vconcat (org-agenda-api--get-default-notify-before))))))
              `(("defaults" . ,defaults)
                ("todos" . ,(vconcat todos)))))))
    (when git-results
      (push `("gitRefresh" . ,(vconcat git-results)) response))
    (insert (json-encode response)))
  (org-agenda-api--track-request))

(defservlet get-todays-agenda application/json ()
  "Endpoint: Return today's scheduled and deadlined items as JSON."
  (insert (json-encode
           (mapcar #'org-agenda-api--item-to-json
                   (org-agenda-api--get-today-agenda))))
  (org-agenda-api--track-request))

(defservlet agenda application/json (_path query)
  "Endpoint: Return org-agenda entries as JSON.
Accepts optional query params:
  - 'span' (day or week, defaults to day)
  - 'date' (YYYY-MM-DD format, defaults to today)
  - 'start_date' (YYYY-MM-DD, start of date range, defaults to date)
  - 'end_date' (YYYY-MM-DD, end of date range for custom ranges)
  - 'today' (YYYY-MM-DD, date to treat as 'today' for overdue calculations)
  - 'include_overdue' (true/1) to include overdue items from previous days (default: false)
  - 'include_completed' (true/1) to include items completed on this date (default: false)
  - 'include_archives' (true/1) to include archive files/trees
  - 'overdue_behavior' (original/today/both, controls where overdue items appear)
  - 'refresh' (true/1) to git pull repos first.

For span=day (default), returns flat 'entries' array for backwards compatibility.
For span=week or when end_date is provided, returns 'days' object grouped by date."
  (let* ((span-param (cadr (assoc "span" query)))
         (date-param (cadr (assoc "date" query)))
         (start-date-param (cadr (assoc "start_date" query)))
         (end-date-param (cadr (assoc "end_date" query)))
         (today-param (cadr (assoc "today" query)))
         (include-overdue-param (cadr (assoc "include_overdue" query)))
         (include-completed-param (cadr (assoc "include_completed" query)))
         (include-archives-param (cadr (assoc "include_archives" query)))
         (overdue-behavior-param (cadr (assoc "overdue_behavior" query)))
         (refresh-param (cadr (assoc "refresh" query)))
         (git-results (when (member refresh-param '("true" "1"))
                        (org-agenda-api--git-refresh-all)))
         (span (if (string= span-param "week") 'week 'day))
         (include-overdue (member include-overdue-param '("true" "1")))
         (include-completed (member include-completed-param '("true" "1")))
         (include-archives (org-agenda-api--include-archives-p include-archives-param))
         (overdue-behavior (or overdue-behavior-param "original"))
         ;; Use requested date or default to today (using calendar-current-date for testability)
         (calendar-today (calendar-current-date))
         (today-str (format "%04d-%02d-%02d"
                            (nth 2 calendar-today) (nth 0 calendar-today) (nth 1 calendar-today)))
         (effective-today (or today-param today-str))
         (effective-start (or start-date-param date-param today-str))
         ;; Determine if multi-day mode
         (multi-day-p (or end-date-param (eq span 'week)))
         (response
          (org-agenda-api--with-archives include-archives
            (if multi-day-p
                ;; Multi-day: return grouped by day
                (org-agenda-api--build-multi-day-response
                 span effective-start end-date-param effective-today
                 include-overdue include-completed overdue-behavior)
              ;; Single day: backwards compatible flat format
              (let ((entries (org-agenda-api--run-agenda span effective-start include-overdue include-completed)))
                `(("span" . ,(symbol-name span))
                  ("date" . ,effective-start)
                  ("entries" . ,(vconcat entries))))))))
    (when git-results
      (push `("gitRefresh" . ,(vconcat git-results)) response))
    (insert (json-encode response)))
  (org-agenda-api--track-request))

(defservlet capture-templates application/json ()
  "Endpoint: Return registered capture templates and their prompts."
  (condition-case err
      (let ((templates-data (org-agenda-api--get-all-templates-json)))
        (message "[org-agenda-api] /capture-templates: returning %d templates"
                 (length templates-data))
        (insert (json-encode templates-data)))
    (error
     (message "[org-agenda-api] /capture-templates ERROR: %S" err)
     (message "[org-agenda-api] org-agenda-api-capture-templates: %S"
              org-agenda-api-capture-templates)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(format "Server error: %S" err)))))))
  (org-agenda-api--track-request))

(defservlet todo-states application/json ()
  "Endpoint: Return configured TODO states.
Returns active (not-done) states and done states separately."
  (insert (json-encode (org-agenda-api--get-todo-states)))
  (org-agenda-api--track-request))

(defservlet filter-options application/json ()
  "Endpoint: Return all available filter options for the UI.
Returns todoStates, priorities, tags, and categories."
  (condition-case err
      (progn
        (message "[org-agenda-api] /filter-options: fetching options...")
        (let ((result (org-agenda-api--get-filter-options)))
          (message "[org-agenda-api] /filter-options: got %d todo states, %d priorities, %d tags, %d categories"
                   (length (cdr (assoc "todoStates" result)))
                   (length (cdr (assoc "priorities" result)))
                   (length (cdr (assoc "tags" result)))
                   (length (cdr (assoc "categories" result))))
          (insert (json-encode result))))
    (error
     (message "[org-agenda-api] /filter-options ERROR: %S" err)
     (httpd-error t 500 (format "Error: %S" err))))
  (org-agenda-api--track-request))

(defservlet notifications application/json (_path query)
  "Endpoint: Return items with upcoming notifications.
Accepts optional query params:
  - 'asOf' (ISO datetime): reference time for notification calculations
If 'asOf' is provided, calculates notifications as if it were that time."
  (condition-case err
      (let* ((as-of-param (cadr (assoc "asOf" query)))
             (as-of-time (when as-of-param
                           (condition-case nil
                               (encode-time (parse-time-string as-of-param))
                             (error nil))))
             (notifications (org-agenda-api--get-upcoming-notifications as-of-time))
             (defaults (org-agenda-api--get-default-notify-before))
             (response `(,@(when as-of-time
                             `(("asOf" . ,(format-time-string "%Y-%m-%dT%H:%M:%S" as-of-time))))
                         ("defaultNotifyBefore" . ,(vconcat defaults))
                         ("count" . ,(length notifications))
                         ("notifications" . ,(vconcat notifications)))))
        (message "[org-agenda-api] /notifications: %d notifications%s"
                 (length notifications)
                 (if as-of-time (format " as-of %s" as-of-param) ""))
        (insert (json-encode response)))
    (error
     (message "[org-agenda-api] /notifications ERROR: %S" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(format "Server error: %S" err)))))))
  (org-agenda-api--track-request))

(defservlet agenda-files application/json (_path query)
  "Endpoint: Return the list of org-agenda-files as JSON.
Accepts optional query param:
  - 'include_archives' (true/1) to include archive files."
  (let* ((include-archives-param (cadr (assoc "include_archives" query)))
         (include-archives (org-agenda-api--include-archives-p include-archives-param))
         (files (if include-archives
                    (org-agenda-api--agenda-files-with-archives org-agenda-files)
                  (mapcar #'expand-file-name org-agenda-files)))
         (file-info (mapcar (lambda (f)
                              `(("path" . ,f)
                                ("exists" . ,(if (file-exists-p f) t :json-false))
                                ("readable" . ,(if (file-readable-p f) t :json-false))))
                            files))
         (response `(("count" . ,(length files))
                     ("files" . ,(vconcat file-info)))))
    (insert (json-encode response)))
  (org-agenda-api--track-request))

(defservlet custom-views application/json ()
  "Endpoint: Return list of available custom agenda views."
  (condition-case err
      (let* ((views (org-agenda-api--list-custom-views))
             (response `(("views" . ,(vconcat views)))))
        (message "[org-agenda-api] /custom-views: returning %d views"
                 (length views))
        (insert (json-encode response)))
    (error
     (message "[org-agenda-api] /custom-views ERROR: %S" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(format "Server error: %S" err)))))))
  (org-agenda-api--track-request))

(defservlet metadata application/json ()
  "Endpoint: Return all app metadata in a single request.
Returns templates, filterOptions, todoStates, customViews, categoryTypes, habitConfig, and any errors."
  (let ((result '())
        (errors '()))
    ;; Collect templates
    (condition-case err
        (push `("templates" . ,(org-agenda-api--get-all-templates-json)) result)
      (error
       (push (format "templates: %s" (error-message-string err)) errors)
       (push '("templates" . nil) result)))
    ;; Collect filter options
    (condition-case err
        (push `("filterOptions" . ,(org-agenda-api--get-filter-options)) result)
      (error
       (push (format "filterOptions: %s" (error-message-string err)) errors)
       (push '("filterOptions" . nil) result)))
    ;; Collect todo states
    (condition-case err
        (push `("todoStates" . ,(org-agenda-api--get-todo-states)) result)
      (error
       (push (format "todoStates: %s" (error-message-string err)) errors)
       (push '("todoStates" . nil) result)))
    ;; Collect custom views
    (condition-case err
        (let ((views (org-agenda-api--list-custom-views)))
          (push `("customViews" . (("views" . ,(vconcat views)))) result))
      (error
       (push (format "customViews: %s" (error-message-string err)) errors)
       (push '("customViews" . nil) result)))
    ;; Collect category types
    (condition-case err
        (push `("categoryTypes" . ,(org-agenda-api--get-category-types)) result)
      (error
       (push (format "categoryTypes: %s" (error-message-string err)) errors)
       (push '("categoryTypes" . nil) result)))
    ;; Collect habit config (if org-window-habit integration is available)
    (condition-case err
        (if (fboundp 'org-agenda-api--get-habit-config)
            (push `("habitConfig" . ,(org-agenda-api--get-habit-config)) result)
          (push `("habitConfig" . (("status" . "ok") ("enabled" . :json-false))) result))
      (error
       (push (format "habitConfig: %s" (error-message-string err)) errors)
       (push '("habitConfig" . nil) result)))
    ;; Collect exposed functions
    (condition-case err
        (push `("exposedFunctions" . ,(vconcat (org-agenda-api--get-exposed-functions))) result)
      (error
       (push (format "exposedFunctions: %s" (error-message-string err)) errors)
       (push '("exposedFunctions" . []) result)))
    ;; Add errors array
    (push `("errors" . ,(vconcat (nreverse errors))) result)
    (insert (json-encode (nreverse result))))
  (org-agenda-api--track-request))

(defservlet custom-view application/json (_path query)
  "Endpoint: Run a custom agenda view and return entries as JSON.
Accepts query params:
  - 'key' (required): The custom agenda command key
  - 'refresh' (optional): If 'true' or '1', git pull repos first."
  (let* ((key (cadr (assoc "key" query)))
         (refresh-param (cadr (assoc "refresh" query)))
         (git-results (when (member refresh-param '("true" "1"))
                        (org-agenda-api--git-refresh-all))))
    (if (or (null key) (string= key ""))
        (insert (json-encode `(("status" . "error")
                               ("message" . "Missing required 'key' parameter"))))
      (let* ((name (org-agenda-api--get-custom-view-name key))
             (entries (org-agenda-api--run-custom-view key))
             (response `(("key" . ,key)
                         ("name" . ,name)
                         ("entries" . ,(vconcat entries)))))
        (when git-results
          (push `("gitRefresh" . ,(vconcat git-results)) response))
        (insert (json-encode response)))))
  (org-agenda-api--track-request))

;;; Mutation Endpoints

(defservlet capture application/json (_path _query headers)
  "Endpoint: Capture using a registered template with provided values."
  (condition-case err
      (let* ((content-header (cadr (assoc "Content" headers)))
             (json-data (json-parse-string content-header))
             (template-key (gethash "template" json-data))
             (values-hash (gethash "values" json-data))
             ;; Convert hash-table to alist
             (values (let (alist)
                       (maphash (lambda (k v) (push (cons k v) alist)) values-hash)
                       alist))
             (result (org-agenda-api--capture-with-template template-key values)))
        (insert (json-encode result)))
    (error
     ;; Return error as JSON with appropriate status
     ;; Note: simple-httpd doesn't have great error handling, so we return 200 with error in body
     ;; A better approach would need custom error handling
     (org-agenda-api--log-error-with-backtrace "/capture" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defservlet update application/json (_path _query headers)
  "Endpoint: Update a TODO's state, title, scheduled date, deadline, priority, tags, effort, or properties.
Accepts JSON body with:
  - id: org-id of the todo (preferred)
  - file: file path (fallback)
  - pos: position in file (fallback)
  - title: heading title (can match by title alone or with file)
  - state: new TODO state (e.g., TODO, DONE, STARTED, etc.)
  - new_title: new title to set for the heading
  - scheduled: object {date, time?, repeater?} or null to clear
    - date: YYYY-MM-DD (required)
    - time: HH:MM (optional)
    - repeater: {type: +|++|.+, value: number, unit: d|w|m|y} (optional)
  - deadline: object {date, time?, repeater?} or null to clear (same format as scheduled)
  - priority: A, B, C, or null to clear
  - tags: array of tag strings to set, or empty array to clear
  - effort: Org duration string or null to clear
  - properties: object of property name/value pairs to set/update
Returns updated todo with new file and pos for cache update."
  (condition-case err
      (catch 'done
        (let* ((content-header (cadr (assoc "Content" headers)))
               (json-data (json-parse-string content-header))
               (id (gethash "id" json-data))
               (file (gethash "file" json-data))
               (pos (gethash "pos" json-data))
               (title (gethash "title" json-data))
               (state (gethash "state" json-data))
               (new-title (gethash "new_title" json-data))
               (scheduled (gethash "scheduled" json-data))
               (deadline (gethash "deadline" json-data))
               (priority (gethash "priority" json-data))
               (tags (gethash "tags" json-data))
               (effort (gethash "effort" json-data))
               (properties (gethash "properties" json-data))
               (body (gethash "body" json-data))
               (location nil)
               (updates nil))
          ;; Log incoming request for debugging
        (message "[/update] Request: id=%s file=%s pos=%s title=%s state=%s new_title=%s scheduled=%s deadline=%s priority=%s effort=%s"
                 id file pos title state new-title scheduled deadline priority effort)
        ;; Check for unrecognized fields
        (let ((allowed-fields '("id" "file" "pos" "title" "state" "new_title" "scheduled" "deadline" "priority" "tags" "effort" "properties" "body"))
              (unrecognized nil))
          (maphash (lambda (key _value)
                     (unless (member key allowed-fields)
                       (push key unrecognized)))
                   json-data)
          (when unrecognized
            (message "[/update] ERROR: Unrecognized fields: %s" unrecognized)
            (insert (json-encode `(("status" . "error")
                                   ("message" . ,(format "Unrecognized fields: %s. Did you mean 'scheduled' instead of 'schedule'?"
                                                         (string-join unrecognized ", "))))))
            (throw 'done nil)))
        ;; Build updates alist (include keys even if value is nil, to signal clearing)
        ;; Use :not-found sentinel to properly detect if key exists in JSON
        (unless (eq (gethash "state" json-data :not-found) :not-found)
          (push (cons "state" (if (eq state :null) nil state)) updates))
        (unless (eq (gethash "new_title" json-data :not-found) :not-found)
          (push (cons "new_title" (if (eq new-title :null) nil new-title)) updates))
        (unless (eq (gethash "scheduled" json-data :not-found) :not-found)
          (push (cons "scheduled" (if (eq scheduled :null) nil scheduled)) updates))
        (unless (eq (gethash "deadline" json-data :not-found) :not-found)
          (push (cons "deadline" (if (eq deadline :null) nil deadline)) updates))
        (unless (eq (gethash "priority" json-data :not-found) :not-found)
          (push (cons "priority" (if (eq priority :null) nil priority)) updates))
        (unless (eq (gethash "tags" json-data :not-found) :not-found)
          (push (cons "tags" (if (eq tags :null) nil tags)) updates))
        (unless (eq (gethash "effort" json-data :not-found) :not-found)
          (push (cons "effort" (if (eq effort :null) nil effort)) updates))
        ;; Handle properties - convert hash-table to alist
        (unless (eq (gethash "properties" json-data :not-found) :not-found)
          (let ((props-alist nil))
            (when (and properties (hash-table-p properties))
              (maphash (lambda (k v)
                         (push (cons k (if (eq v :null) nil v)) props-alist))
                       properties))
            (push (cons "properties" props-alist) updates)))
        ;; Handle body
        (unless (eq (gethash "body" json-data :not-found) :not-found)
          (push (cons "body" (if (eq body :null) nil body)) updates))
        (message "[/update] Updates to apply: %S" updates)
        ;; Try to find by ID first
        (setq location (org-agenda-api--find-todo-by-id id))
        (when location (message "[/update] Found by ID"))
        ;; Fall back to file+pos+title (includes lenient matching)
        (unless location
          (setq location (org-agenda-api--find-todo-by-file-pos-title file pos title))
          (when location (message "[/update] Found by file+pos+title")))
        ;; Fall back to file+title strict match (handles position drift)
        (unless location
          (setq location (org-agenda-api--find-todo-by-file-title file title))
          (when location (message "[/update] Found by file+title")))
        ;; Fall back to title only strict match across all agenda files
        (unless location
          (setq location (org-agenda-api--find-todo-by-title title))
          (when location (message "[/update] Found by title only")))
        ;; Fall back to file+title lenient match (handles whitespace/unicode differences)
        (unless location
          (setq location (org-agenda-api--find-todo-by-file-title file title t))
          (when location (message "[/update] Found by file+title (lenient)")))
        ;; Fall back to title only lenient match across all agenda files
        (unless location
          (setq location (org-agenda-api--find-todo-by-title title t))
          (when location (message "[/update] Found by title only (lenient)")))
        (message "[/update] Location: %S" location)
        (if location
            (let ((result (org-agenda-api--update-todo-at
                           (car location) (cdr location) updates)))
              (insert (json-encode result)))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Todo not found")))))))
    (error
     (org-agenda-api--log-error-with-backtrace "/update" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defservlet complete application/json (_path _query headers)
  "Endpoint: Mark a TODO as complete.
Accepts JSON body with:
  - id: org-id of the todo (preferred)
  - file: file path (fallback)
  - pos: position in file (fallback)
  - title: heading title (for verification)
  - state: new state (optional, defaults to DONE)
  - override_date: ISO date string to use as effective date for the state change
                   (affects LOGBOOK timestamp, useful for retroactive completions)"
  (condition-case err
      (let* ((content-header (cadr (assoc "Content" headers)))
             (json-data (json-parse-string content-header))
             (id (gethash "id" json-data))
             (file (gethash "file" json-data))
             (pos (gethash "pos" json-data))
             (title (gethash "title" json-data))
             (new-state (gethash "state" json-data))
             (override-date-str (gethash "override_date" json-data))
             (override-date (when (and override-date-str
                                       (not (eq override-date-str :null))
                                       (not (string-empty-p override-date-str)))
                              (org-agenda-api--parse-datetime override-date-str)))
             (location nil))
        ;; If both file+pos AND id are provided, prefer file+pos since it's more
        ;; reliable (org-id-find can return stale cached paths from previous runs)
        (when (and file pos)
          (setq location (org-agenda-api--find-todo-by-file-pos-title file pos title)))
        ;; Fall back to ID lookup if file+pos wasn't found or not provided
        (unless location
          (setq location (org-agenda-api--find-todo-by-id id)))
        ;; Fall back to file+title (for when position drifted)
        (unless location
          (setq location (org-agenda-api--find-todo-by-file-pos-title file pos title)))
        ;; Fall back to file+title strict match (handles position drift)
        (unless location
          (setq location (org-agenda-api--find-todo-by-file-title file title)))
        ;; Fall back to title only strict match across all agenda files
        (unless location
          (setq location (org-agenda-api--find-todo-by-title title)))
        ;; Fall back to file+title lenient match (handles whitespace/unicode differences)
        (unless location
          (setq location (org-agenda-api--find-todo-by-file-title file title t))
          (when location (message "[/complete] Found by file+title (lenient)")))
        ;; Fall back to title only lenient match across all agenda files
        (unless location
          (setq location (org-agenda-api--find-todo-by-title title t))
          (when location (message "[/complete] Found by title only (lenient)")))
        (if location
            (let ((result (org-agenda-api--complete-todo-at
                           (car location) (cdr location) new-state override-date)))
              (insert (json-encode result)))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Todo not found"))))))
    (error
     (org-agenda-api--log-error-with-backtrace "/complete" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defservlet set-state application/json (_path _query headers)
  "Endpoint: Change a TODO's state.
This is an alias for /complete with a more accurate name, since it supports
any state transition (not just completion).
Accepts JSON body with:
  - id: org-id of the todo (preferred)
  - file: file path (fallback)
  - pos: position in file (fallback)
  - title: heading title (for verification)
  - state: new state (required for this endpoint)
  - override_date: ISO date string to use as effective date for the state change
                   (affects LOGBOOK timestamp, useful for retroactive state changes)"
  (condition-case err
      (catch 'done
        (let* ((content-header (cadr (assoc "Content" headers)))
               (json-data (json-parse-string content-header))
               (id (gethash "id" json-data))
               (file (gethash "file" json-data))
               (pos (gethash "pos" json-data))
               (title (gethash "title" json-data))
               (new-state (gethash "state" json-data))
               (override-date-str (gethash "override_date" json-data))
               (override-date (when (and override-date-str
                                         (not (eq override-date-str :null))
                                         (not (string-empty-p override-date-str)))
                                (org-agenda-api--parse-datetime override-date-str)))
               (location nil))
          ;; Validate state is provided for this endpoint
          (unless new-state
            (insert (json-encode `(("status" . "error")
                                   ("message" . "Missing required 'state' parameter"))))
            (throw 'done nil))
          ;; Try to find by ID first
          (setq location (org-agenda-api--find-todo-by-id id))
          ;; Fall back to file+pos+title (includes lenient matching)
          (unless location
            (setq location (org-agenda-api--find-todo-by-file-pos-title file pos title)))
          ;; Fall back to file+title strict match (handles position drift)
          (unless location
            (setq location (org-agenda-api--find-todo-by-file-title file title)))
          ;; Fall back to title only strict match across all agenda files
          (unless location
            (setq location (org-agenda-api--find-todo-by-title title)))
          ;; Fall back to file+title lenient match (handles whitespace/unicode differences)
          (unless location
            (setq location (org-agenda-api--find-todo-by-file-title file title t))
            (when location (message "[/set-state] Found by file+title (lenient)")))
          ;; Fall back to title only lenient match across all agenda files
          (unless location
            (setq location (org-agenda-api--find-todo-by-title title t))
            (when location (message "[/set-state] Found by title only (lenient)")))
          (if location
              (let ((result (org-agenda-api--complete-todo-at
                             (car location) (cdr location) new-state override-date)))
                (insert (json-encode result)))
            (insert (json-encode `(("status" . "error")
                                   ("message" . "Todo not found")))))))
    (error
     (org-agenda-api--log-error-with-backtrace "/set-state" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defservlet delete application/json (_path _query headers)
  "Endpoint: Delete an org item permanently.
Accepts JSON body with either:
  - id: org-id to locate the item
  - file + pos: direct file location
Optional:
  - include_children: if true, delete subtree even if item has children"
  (let* ((content-header (cadr (assoc "Content" headers)))
         (json-data (condition-case parse-err
                        (json-parse-string content-header)
                      (error
                       (org-agenda-api--log 'error "/delete: Failed to parse JSON body: %s (raw: %s)"
                                            (error-message-string parse-err) content-header)
                       nil)))
         (id (and json-data (gethash "id" json-data)))
         (file (and json-data (gethash "file" json-data)))
         (position (and json-data (gethash "pos" json-data)))
         (include-children (and json-data (eq (gethash "include_children" json-data) t))))
    ;; Log the incoming request parameters
    (org-agenda-api--log 'info "/delete: Request params - id=%S, file=%S, pos=%S, include_children=%S"
                         id file position include-children)
    (condition-case err
        (if (null json-data)
            (insert (json-encode `(("status" . "error")
                                   ("code" . "INVALID_JSON")
                                   ("message" . "Failed to parse request body as JSON"))))
          (let ((result (org-agenda-api--delete-item id file position include-children)))
            (org-agenda-api--log 'info "/delete: Success - deleted '%s'" (cdr (assoc "title" result)))
            (insert (json-encode result))))
      (org-agenda-api-delete-error
       (let* ((error-data (cdr err))
              (code (car error-data))
              (message (cadr error-data)))
         (org-agenda-api--log 'error "/delete: %s - %s (id=%S, file=%S, pos=%S)"
                              code message id file position)
         (org-agenda-api--log 'error "/delete: Backtrace:\n%s" (org-agenda-api--capture-backtrace))
         (insert (json-encode `(("status" . "error")
                                ("code" . ,code)
                                ("message" . ,message)
                                ("request" . (("id" . ,(or id :json-null))
                                              ("file" . ,(or file :json-null))
                                              ("pos" . ,(or position :json-null))
                                              ("include_children" . ,(if include-children t :json-false)))))))))
      (error
       (org-agenda-api--log-error-with-backtrace "/delete" err)
       (org-agenda-api--log 'error "/delete: Request was - id=%S, file=%S, pos=%S, include_children=%S"
                            id file position include-children)
       (insert (json-encode `(("status" . "error")
                              ("code" . "INTERNAL_ERROR")
                              ("message" . ,(error-message-string err))
                              ("request" . (("id" . ,(or id :json-null))
                                            ("file" . ,(or file :json-null))
                                            ("pos" . ,(or position :json-null))
                                            ("include_children" . ,(if include-children t :json-false))))))))))
  (org-agenda-api--track-request))

(defservlet delete-logbook-entry application/json (_path _query headers)
  "Endpoint: Delete a specific LOGBOOK entry from an org item.
Accepts JSON body with:
  - id: org-id to locate the item (or use file + pos)
  - file + pos: direct file location
  - date: the date of the logbook entry to delete (YYYY-MM-DD)
Optional:
  - type: filter to only delete entries of this type (\"state-change\", \"note\")"
  (let* ((content-header (cadr (assoc "Content" headers)))
         (json-data (condition-case parse-err
                        (json-parse-string content-header)
                      (error
                       (org-agenda-api--log 'error "/delete-logbook-entry: Failed to parse JSON: %s"
                                            (error-message-string parse-err))
                       nil)))
         (id (and json-data (gethash "id" json-data)))
         (file (and json-data (gethash "file" json-data)))
         (pos (and json-data (gethash "pos" json-data)))
         (date (and json-data (gethash "date" json-data)))
         (entry-type (and json-data (gethash "type" json-data))))
    (org-agenda-api--log 'info "/delete-logbook-entry: Request - id=%S, file=%S, pos=%S, date=%S, type=%S"
                         id file pos date entry-type)
    (condition-case err
        (cond
         ((null json-data)
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Failed to parse request body as JSON")))))
         ((null date)
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Missing required parameter: date")))))
         ((and (null id) (or (null file) (null pos)))
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Must provide either 'id' or both 'file' and 'pos'")))))
         (t
          ;; Resolve location from id if provided
          (let* ((location (if id
                               (org-id-find id)
                             (cons file pos)))
                 (target-file (car location))
                 (target-pos (cdr location)))
            (if (null location)
                (insert (json-encode `(("status" . "error")
                                       ("message" . ,(format "Item not found with id: %s" id)))))
              (let ((result (org-agenda-api--delete-logbook-entry
                             target-file target-pos date entry-type)))
                (org-agenda-api--log 'info "/delete-logbook-entry: Result - %S"
                                     (cdr (assoc "status" result)))
                (insert (json-encode result)))))))
      (error
       (org-agenda-api--log-error-with-backtrace "/delete-logbook-entry" err)
       (insert (json-encode `(("status" . "error")
                              ("message" . ,(error-message-string err))))))))
  (org-agenda-api--track-request))

;;; Utility Endpoints

(defservlet health application/json ()
  "Endpoint: Health check for monitoring systems (nginx, supervisord, etc.).
Returns basic status information and capture readiness check."
  (let* ((uptime (when org-agenda-api--start-time
                   (float-time (time-subtract (current-time) org-agenda-api--start-time))))
         (capture-check (catch 'unhealthy (org-agenda-api--check-capture-ready)))
         (healthy (null capture-check))
         (response `(("status" . ,(if healthy "ok" "unhealthy"))
                     ("uptime" . ,uptime)
                     ("requests" . ,org-agenda-api--request-count))))
    (when capture-check
      (push `("captureStatus" . ,capture-check) response)
      (org-agenda-api--log 'warn "Health check failed: %s" capture-check))
    (insert (json-encode response))
    ;; Return 503 if unhealthy so supervisord/nginx can detect it
    (unless healthy
      (httpd-error httpd-current-proc 503))))

(defservlet version application/json ()
  "Endpoint: Return version information including semantic version and git commit hash.
The git commit is read from the ORG_AGENDA_API_GIT_COMMIT environment variable,
which is set at build time by the Nix flake."
  (let* ((git-commit (or (getenv "ORG_AGENDA_API_GIT_COMMIT") "unknown"))
         (response `(("version" . ,org-agenda-api-version)
                     ("gitCommit" . ,git-commit))))
    (insert (json-encode response))))

(defservlet debug-config application/json ()
  "Endpoint: Return current org configuration for debugging."
  (let ((response `(("org-log-into-drawer" . ,org-log-into-drawer)
                    ("org-log-done" . ,org-log-done)
                    ("org-log-repeat" . ,org-log-repeat)
                    ("org-log-reschedule" . ,org-log-reschedule)
                    ("org-log-redeadline" . ,org-log-redeadline)
                    ("org-todo-keywords" . ,(format "%S" org-todo-keywords))
                    ("custom-elisp-file" . ,(getenv "ORG_API_CUSTOM_ELISP")))))
    (insert (json-encode response))))

(defservlet restart application/json ()
  "Endpoint: Restart Emacs.
Exits gracefully, allowing supervisord to restart the process."
  (insert (json-encode `(("status" . "restarting"))))
  ;; Use run-at-time to allow the response to be sent before exiting
  (run-at-time 0.1 nil #'kill-emacs 0))

(defservlet reload application/json ()
  "Endpoint: Reload all org files from disk and invalidate cache.
Useful for testing when files are modified externally (e.g., git reset).
Kills all org-agenda-files buffers (they'll be re-read on next access)
and clears the todo cache."
  (let ((killed-count 0))
    ;; Kill all org-agenda-files buffers so they'll be re-read from disk
    (dolist (file (org-agenda-files))
      (let ((buf (get-file-buffer file)))
        (when buf
          (with-current-buffer buf
            ;; Mark buffer as not modified to avoid save prompts
            (set-buffer-modified-p nil))
          (kill-buffer buf)
          (setq killed-count (1+ killed-count)))))
    ;; Invalidate the cache
    (org-agenda-api--invalidate-cache)
    ;; Return status
    (insert (json-encode
             `(("status" . "ok")
               ("killedBuffers" . ,killed-count))))))

(defservlet trigger-sync application/json ()
  "Endpoint: Touch an org file to trigger git-sync-rs to sync.
This is useful when you want to force git-sync-rs to run a sync cycle
without waiting for its normal interval."
  (condition-case err
      (let ((result (org-agenda-api--trigger-sync)))
        (insert (json-encode result)))
    (error
     (org-agenda-api--log-error-with-backtrace "/trigger-sync" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(defservlet call-function application/json (_path _query headers)
  "Endpoint: Call a whitelisted elisp function.
Accepts JSON body with:
  - function: name of the function to call (must be in org-agenda-api-exposed-functions)

The function is called with no arguments. Returns immediately with status ok.
This is fire-and-forget - use for batch operations like rescheduling."
  (condition-case err
      (let* ((content-header (cadr (assoc "Content" headers)))
             (json-data (json-parse-string content-header))
             (func-name (gethash "function" json-data)))
        (cond
         ((null func-name)
          (insert (json-encode `(("status" . "error")
                                 ("message" . "Missing required 'function' parameter")))))
         ((not (org-agenda-api--function-whitelisted-p func-name))
          (org-agenda-api--log 'warn "/call-function: Attempted to call non-whitelisted function: %s" func-name)
          (insert (json-encode `(("status" . "error")
                                 ("message" . ,(format "Function not in whitelist: %s" func-name))))))
         (t
          (let ((func-sym (intern func-name)))
            (if (fboundp func-sym)
                (progn
                  (org-agenda-api--log 'info "/call-function: Calling %s" func-name)
                  (funcall func-sym)
                  (insert (json-encode `(("status" . "ok")
                                         ("function" . ,func-name)))))
              (insert (json-encode `(("status" . "error")
                                     ("message" . ,(format "Function not defined: %s" func-name))))))))))
    (error
     (org-agenda-api--log-error-with-backtrace "/call-function" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))

(provide 'org-agenda-api-endpoints)
;;; org-agenda-api-endpoints.el ends here
