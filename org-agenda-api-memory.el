;;; org-agenda-api-memory.el --- Agent memory notes in an org file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison
;; Author: Ivan Malison <IvanMalison@gmail.com>

;;; Commentary:
;; Exposes a single org file of named notes as a small memory store:
;;
;;   GET  /memory?q=&offset=&limit=  search notes
;;   POST /memory/save   {name, text, source?}  keep a note, replacing one of the same name
;;   POST /memory/learn  {name, text, source?}  add a note tagged for review
;;   POST /memory/forget {name}                 delete a note
;;
;; Each note is a top-level heading whose title is its name and whose body is
;; its text.  Notes an agent learned on its own carry the
;; `org-agenda-api-memory-unreviewed-tag' until a person saves over them or
;; removes the tag.

;;; Code:

(require 'json)
(require 'org)
(require 'org-id)
(require 'seq)
(require 'simple-httpd)
(require 'org-agenda-api-core)

(defcustom org-agenda-api-memory-file nil
  "Org file holding memory notes.  When nil the /memory endpoints are disabled."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'org-agenda-api)

(defcustom org-agenda-api-memory-unreviewed-tag "unreviewed"
  "Tag marking notes that were learned rather than explicitly saved."
  :type 'string
  :group 'org-agenda-api)

(defconst org-agenda-api-memory-max-name-length 120)
(defconst org-agenda-api-memory-max-text-length 8000)
(defconst org-agenda-api-memory-default-limit 20)
(defconst org-agenda-api-memory-max-limit 100)

(define-error 'org-agenda-api-memory-error "org-agenda-api memory error")

(defun org-agenda-api--memory-fail (status code message)
  "Signal a memory error with HTTP STATUS, error CODE and MESSAGE."
  (signal 'org-agenda-api-memory-error (list status code message)))

(defun org-agenda-api--memory-buffer ()
  "Return a buffer visiting the memory file, current with the disk."
  (unless org-agenda-api-memory-file
    (org-agenda-api--memory-fail 404 "memory_disabled" "No memory file is configured"))
  (let ((file (expand-file-name org-agenda-api-memory-file)))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert "#+TITLE: Memory\n\n")))
    (let ((buffer (find-file-noselect file t)))
      (with-current-buffer buffer
        (unless (verify-visited-file-modtime buffer)
          (revert-buffer t t t))
        (unless (derived-mode-p 'org-mode)
          (org-mode)))
      buffer)))

(defun org-agenda-api--memory-timestamp ()
  "Return an inactive org timestamp for now."
  (format-time-string (org-time-stamp-format t t)))

(defun org-agenda-api--memory-strip-brackets (timestamp)
  "Return TIMESTAMP without its surrounding brackets, or nil."
  (when (and timestamp (string-match "\\`\\[\\(.*\\)\\]\\'" timestamp))
    (match-string 1 timestamp)))

(defun org-agenda-api--memory-note-at-point ()
  "Return the memory note at the top-level heading at point as an alist."
  (let* ((tags (org-get-tags nil t))
         (end (save-excursion (org-end-of-subtree t t) (point)))
         (text (save-excursion
                 (org-end-of-meta-data t)
                 (string-trim (buffer-substring-no-properties (min (point) end) end)))))
    `(("name" . ,(org-get-heading t t t t))
      ("text" . ,text)
      ("id" . ,(or (org-entry-get nil "ID") :json-null))
      ("created" . ,(or (org-agenda-api--memory-strip-brackets (org-entry-get nil "CREATED")) :json-null))
      ("updated" . ,(or (org-agenda-api--memory-strip-brackets (org-entry-get nil "UPDATED")) :json-null))
      ("source" . ,(or (org-entry-get nil "SOURCE") :json-null))
      ("reviewed" . ,(if (member org-agenda-api-memory-unreviewed-tag tags) :json-false t))
      ("tags" . ,(vconcat (remove org-agenda-api-memory-unreviewed-tag tags))))))

(defun org-agenda-api--memory-notes ()
  "Return every note in the memory file, in file order."
  (with-current-buffer (org-agenda-api--memory-buffer)
    (org-with-wide-buffer
     (goto-char (point-min))
     (let (notes)
       (while (re-search-forward "^\\* " nil t)
         (beginning-of-line)
         (push (org-agenda-api--memory-note-at-point) notes)
         (end-of-line))
       (nreverse notes)))))

(defun org-agenda-api--memory-find (name)
  "Move point to the top-level heading named NAME and return point, or nil."
  (goto-char (point-min))
  (catch 'found
    (while (re-search-forward "^\\* " nil t)
      (beginning-of-line)
      (when (equal (org-get-heading t t t t) name)
        (throw 'found (point)))
      (end-of-line))
    nil))

(defun org-agenda-api--memory-matches-p (note terms)
  "Return non-nil when every one of TERMS occurs in NOTE."
  (let ((haystack (downcase (mapconcat #'identity
                                       (cons (cdr (assoc "name" note))
                                             (cons (cdr (assoc "text" note))
                                                   (append (cdr (assoc "tags" note)) nil)))
                                       "\n"))))
    (seq-every-p (lambda (term) (string-match-p (regexp-quote term) haystack)) terms)))

(defun org-agenda-api--memory-search (query offset limit)
  "Search notes for QUERY, returning LIMIT results starting at OFFSET."
  (let* ((terms (split-string (downcase (or query "")) nil t))
         (matches (seq-filter (lambda (note) (org-agenda-api--memory-matches-p note terms))
                              (org-agenda-api--memory-notes)))
         (by-name (seq-filter
                   (lambda (note)
                     (let ((name (downcase (cdr (assoc "name" note)))))
                       (seq-every-p (lambda (term) (string-match-p (regexp-quote term) name)) terms)))
                   matches))
         (ranked (append by-name (seq-difference matches by-name #'eq)))
         (page (seq-take (seq-drop ranked offset) limit)))
    `(("total" . ,(length ranked))
      ("offset" . ,offset)
      ,@(when (< (+ offset (length page)) (length ranked))
          `(("nextOffset" . ,(+ offset (length page)))))
      ("notes" . ,(vconcat page)))))

(defun org-agenda-api--memory-validate-name (name)
  "Signal unless NAME can be a memory heading."
  (unless (and (stringp name)
               (not (string-empty-p name))
               (equal name (string-trim name))
               (<= (length name) org-agenda-api-memory-max-name-length)
               (not (string-match-p "[\n\r]" name)))
    (org-agenda-api--memory-fail
     400 "invalid_name"
     (format "Name must be one nonblank line of at most %d characters without surrounding spaces"
             org-agenda-api-memory-max-name-length)))
  (with-temp-buffer
    (org-mode)
    (insert "* " name)
    (unless (equal (org-get-heading t t t t) name)
      (org-agenda-api--memory-fail
       400 "invalid_name"
       "Name must not start with a TODO keyword, priority, or COMMENT, nor end with tags"))))

(defun org-agenda-api--memory-validate-text (text)
  "Signal unless TEXT can be a memory body."
  (unless (and (stringp text)
               (not (string-empty-p (string-trim text)))
               (<= (length text) org-agenda-api-memory-max-text-length))
    (org-agenda-api--memory-fail
     400 "invalid_text"
     (format "Text must be nonblank and at most %d characters"
             org-agenda-api-memory-max-text-length))))

(defun org-agenda-api--memory-body (text)
  "Return TEXT as an entry body that cannot start new headings."
  (replace-regexp-in-string "^\\*" " *" (string-trim text) t t))

(defun org-agenda-api--memory-write (name text source unreviewed)
  "Store note NAME with TEXT and SOURCE; tag it for review when UNREVIEWED.
Replaces the body of an existing note of that name, keeping its ID and
CREATED.  Returns (CREATED-P . NOTE)."
  (org-agenda-api--memory-validate-name name)
  (org-agenda-api--memory-validate-text text)
  (with-current-buffer (org-agenda-api--memory-buffer)
    (org-with-wide-buffer
     (let* ((now (org-agenda-api--memory-timestamp))
            (existing (org-agenda-api--memory-find name))
            (created-p (null existing)))
       (when (and existing unreviewed
                  (not (member org-agenda-api-memory-unreviewed-tag (org-get-tags nil t))))
         (org-agenda-api--memory-fail
          409 "conflict"
          "A reviewed note already has this name; learned notes never replace reviewed ones"))
       (if existing
           (let ((body-start (save-excursion (org-end-of-meta-data t) (point)))
                 (end (save-excursion (org-end-of-subtree t t) (point))))
             (delete-region (min body-start end) end)
             (goto-char (min body-start end))
             (unless (bolp) (insert "\n")))
         (goto-char (point-max))
         (unless (bolp) (insert "\n"))
         (insert "* " name "\n"))
       (let ((body-position (point)))
         (insert (org-agenda-api--memory-body text) "\n")
         (goto-char body-position))
       (org-back-to-heading t)
       (org-id-get-create)
       (unless (org-entry-get nil "CREATED")
         (org-entry-put nil "CREATED" now))
       (org-entry-put nil "UPDATED" now)
       (if (and source (not (string-empty-p (string-trim source))))
           (org-entry-put nil "SOURCE" (string-trim source))
         (org-entry-delete nil "SOURCE"))
       (org-set-tags (if unreviewed
                         (seq-uniq (append (org-get-tags nil t)
                                           (list org-agenda-api-memory-unreviewed-tag)))
                       (remove org-agenda-api-memory-unreviewed-tag (org-get-tags nil t))))
       (let ((note (org-agenda-api--memory-note-at-point)))
         (save-buffer)
         (cons created-p note))))))

(defun org-agenda-api--memory-forget (name)
  "Delete note NAME.  Signal when there is no such note."
  (with-current-buffer (org-agenda-api--memory-buffer)
    (org-with-wide-buffer
     (unless (and (stringp name) (org-agenda-api--memory-find name))
       (org-agenda-api--memory-fail 404 "not_found" "No note has that exact name; nothing was deleted"))
     (delete-region (point) (save-excursion (org-end-of-subtree t t) (point)))
     (save-buffer))))

(defun org-agenda-api--memory-request-json (headers)
  "Parse the JSON body from request HEADERS, signaling a 400 on failure."
  (condition-case nil
      (let ((data (org-agenda-api--parse-json-request-body (cadr (assoc "Content" headers)))))
        (unless (hash-table-p data) (error "Not an object"))
        data)
    (error (org-agenda-api--memory-fail 400 "invalid_json" "Request body must be a JSON object"))))

(defun org-agenda-api--memory-query-integer (query name default maximum)
  "Read NAME from QUERY as an integer between 0 and MAXIMUM, else DEFAULT."
  (let ((value (cadr (assoc name query))))
    (cond
     ((null value) default)
     ((and (string-match-p "\\`[0-9]+\\'" value) (<= (string-to-number value) maximum))
      (string-to-number value))
     (t (org-agenda-api--memory-fail
         400 "invalid_query_parameter"
         (format "Query parameter '%s' must be an integer from 0 to %d" name maximum))))))

(defun org-agenda-api--memory-handle (action method query headers)
  "Return the response alist for memory ACTION requested with METHOD."
  (pcase (cons action method)
    (`(nil . "GET")
     (org-agenda-api--memory-search
      (cadr (assoc "q" query))
      (org-agenda-api--memory-query-integer query "offset" 0 most-positive-fixnum)
      (max 1 (org-agenda-api--memory-query-integer
              query "limit" org-agenda-api-memory-default-limit org-agenda-api-memory-max-limit))))
    (`(,(and (or "save" "learn") verb) . "POST")
     (let* ((data (org-agenda-api--memory-request-json headers))
            (result (org-agenda-api--memory-write
                     (gethash "name" data) (gethash "text" data)
                     (let ((source (gethash "source" data))) (and (stringp source) source))
                     (equal verb "learn"))))
       (org-agenda-api--log 'info "/memory/%s: %s %S" verb (if (car result) "created" "updated")
                            (cdr (assoc "name" (cdr result))))
       `(("status" . ,(if (equal verb "learn") "learned" "saved"))
         ("created" . ,(if (car result) t :json-false))
         ("note" . ,(cdr result)))))
    (`("forget" . "POST")
     (let ((name (gethash "name" (org-agenda-api--memory-request-json headers))))
       (org-agenda-api--memory-forget name)
       (org-agenda-api--log 'info "/memory/forget: %S" name)
       `(("status" . "forgotten") ("name" . ,name))))
    (_ (org-agenda-api--memory-fail 404 "not_found" "Unknown memory endpoint"))))

(defservlet memory application/json (path query headers)
  "Endpoint: search and edit memory notes; see `org-agenda-api-memory-file'."
  (condition-case err
      (let* ((parts (split-string (directory-file-name path) "/" t))
             (action (cadr parts)))
        (insert (json-encode (org-agenda-api--memory-handle action (caar headers) query headers))))
    (org-agenda-api-memory-error
     (pcase-let ((`(,status ,code ,message) (cdr err)))
       (insert (json-encode `(("status" . "error") ("code" . ,code) ("message" . ,message))))
       (httpd-send-header t "application/json; charset=utf-8" status)))
    (error
     (org-agenda-api--log-error-with-backtrace "/memory" err)
     (insert (json-encode `(("status" . "error")
                            ("code" . "internal_error")
                            ("message" . ,(error-message-string err)))))
     (httpd-send-header t "application/json; charset=utf-8" 500)))
  (org-agenda-api--track-request))

(provide 'org-agenda-api-memory)
;;; org-agenda-api-memory.el ends here
