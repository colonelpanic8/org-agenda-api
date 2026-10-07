;;; org-agenda-api-notes.el --- Read-only browsing of org notes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison
;; Author: Ivan Malison <IvanMalison@gmail.com>

;;; Commentary:
;; Serves every org file under `org-agenda-api-notes-directories' for reading:
;;
;;   GET /notes?q=&limit=  list notes, or search them when q is given
;;   GET /note?ref=        one note as structured blocks, with its links and
;;                         backlinks
;;
;; A note is a whole file (ref "file:<path>") or a heading with an ID (ref
;; "id:<uuid>").  A file with a file-level ID is addressed by its ID, though
;; its "file:" ref still resolves.  Headings with a TODO keyword are left out
;; of listings and search but can still be opened by ref.
;;
;; The index is a lightweight line scan, refreshed per file whenever its size
;; or modification time changes.  Rendering parses only the requested note
;; with org-element.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'org-element)
(require 'seq)
(require 'subr-x)
(require 'simple-httpd)
(require 'org-agenda-api-core)

(defcustom org-agenda-api-notes-directories nil
  "Directories whose org files are served by /notes and /note.
When nil those endpoints are disabled."
  :type '(repeat directory)
  :group 'org-agenda-api)

(defcustom org-agenda-api-notes-exclude-regexp
  "\\(?:\\`\\|/\\)\\(?:\\.[^/]*/\\|node_modules/\\|[.#][^/]*\\'\\)"
  "Regexp matched against root-relative file paths to leave out of notes."
  :type 'regexp
  :group 'org-agenda-api)

(defconst org-agenda-api-notes-default-search-limit 50)
(defconst org-agenda-api-notes-max-limit 10000)
(defconst org-agenda-api-notes-context-length 200)

(define-error 'org-agenda-api-notes-error "org-agenda-api notes error")

(defun org-agenda-api--notes-fail (status code message)
  "Signal a notes error with HTTP STATUS, error CODE and MESSAGE."
  (signal 'org-agenda-api-notes-error (list status code message)))

(cl-defstruct (org-agenda-api--notes-file
               (:constructor org-agenda-api--notes-file-create)
               (:copier nil))
  path rel mtime size notes)

(cl-defstruct (org-agenda-api--note
               (:constructor org-agenda-api--note-create)
               (:copier nil))
  ref id file title olp level todo tags links text)

(defvar org-agenda-api--notes-files (make-hash-table :test 'equal)
  "Indexed files keyed by absolute path.")

;;; Scanning

(defconst org-agenda-api--notes-link-regexp
  "\\[\\[\\([^]\n]+\\)\\]\\(?:\\[\\([^]\n]*\\)\\]\\)?\\]"
  "Bracket link; group 1 is the target, group 2 the description.")

(defun org-agenda-api--notes-strip-links (string)
  "Return STRING with bracket links replaced by their descriptions."
  (replace-regexp-in-string
   org-agenda-api--notes-link-regexp
   (lambda (match)
     (string-match org-agenda-api--notes-link-regexp match)
     (let ((description (match-string 2 match)))
       (if (and description (not (string-empty-p description)))
           description
         (match-string 1 match))))
   string t t))

(defun org-agenda-api--notes-keywords-from-sequences (sequences)
  "Return the TODO keywords named in `org-todo-keywords'-style SEQUENCES."
  (let (keywords)
    (dolist (sequence sequences)
      (dolist (word (if (consp sequence) (cdr sequence) (list sequence)))
        (when (and (stringp word) (not (equal word "|")))
          (push (replace-regexp-in-string "(.*)\\'" "" word) keywords))))
    keywords))

(defun org-agenda-api--notes-todo-keywords ()
  "Return the TODO keywords in effect for the file in the current buffer."
  (let ((keywords (org-agenda-api--notes-keywords-from-sequences org-todo-keywords)))
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search t))
        (while (re-search-forward "^#\\+\\(?:SEQ_\\|TYP_\\)?TODO:[ \t]*\\(.*\\)$" nil t)
          (setq keywords (append (split-string
                                  (replace-regexp-in-string "([^)]*)\\||" " " (match-string 1)))
                                 keywords)))))
    (delete-dups keywords)))

(defun org-agenda-api--notes-parse-heading (text keywords)
  "Split heading TEXT into (TITLE TODO TAGS) given TODO KEYWORDS."
  (let ((case-fold-search nil)
        todo tags)
    (when (string-match "[ \t]+\\(:\\(?:[[:alnum:]_@#%]+:\\)+\\)[ \t]*\\'" text)
      (setq tags (split-string (match-string 1 text) ":" t)
            text (substring text 0 (match-beginning 0))))
    (when (and (string-match "\\`\\([^ \t]+\\)\\(?:[ \t]+\\|\\'\\)" text)
               (member (match-string 1 text) keywords))
      (setq todo (match-string 1 text)
            text (substring text (match-end 0))))
    (setq text (replace-regexp-in-string "\\`\\(?:\\[#.\\][ \t]*\\)?\\(?:COMMENT\\(?:[ \t]+\\|\\'\\)\\)?" "" text))
    (setq text (replace-regexp-in-string "[ \t]*\\[[0-9]*\\(?:%\\|/[0-9]*\\)\\]" "" text))
    (list (string-trim (org-agenda-api--notes-strip-links text)) todo tags)))

(defun org-agenda-api--notes-drawer-id ()
  "Return the ID in the property drawer at the start of the next line, if any.
Point should be at the end of a heading line.  Planning lines are skipped."
  (save-excursion
    (forward-line 1)
    (while (looking-at-p "^[ \t]*\\(?:SCHEDULED\\|DEADLINE\\|CLOSED\\):")
      (forward-line 1))
    (when (looking-at-p "^[ \t]*:PROPERTIES:[ \t]*$")
      (let ((end (save-excursion (re-search-forward "^[ \t]*:END:[ \t]*$" nil t))))
        (when (and end (re-search-forward "^[ \t]*:ID:[ \t]+\\([^ \t\n]+\\)" end t))
          (match-string-no-properties 1))))))

(defun org-agenda-api--notes-segment-links (start end)
  "Return the links between START and END as (KIND TARGET CONTEXT) lists.
KIND is `id' or `file'; file targets are absolute paths."
  (let (links)
    (save-excursion
      (goto-char start)
      (while (re-search-forward org-agenda-api--notes-link-regexp end t)
        (let* ((target (match-string-no-properties 1))
               (link
                (cond
                 ((string-match "\\`id:\\([^:]+\\)" target)
                  (list 'id (match-string 1 target)))
                 ((string-match "\\`\\(?:file:\\)?\\([^:]*\\.org\\)\\(?:::.*\\)?\\'" target)
                  (list 'file (expand-file-name (match-string 1 target)))))))
          (when link
            (let ((context (replace-regexp-in-string
                            "\\`\\(?:\\*+\\|[-+]\\|[0-9]+[.)]\\)[ \t]+\\(?:\\[[ Xx-]\\][ \t]+\\)?" ""
                            (string-trim
                             (org-agenda-api--notes-strip-links
                              (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position)))))))
              (push (append link
                            (list (truncate-string-to-width
                                   context org-agenda-api-notes-context-length nil nil "…")))
                    links))))))
    (nreverse links)))

(defun org-agenda-api--notes-scan-buffer (rel)
  "Return the notes in the current buffer, whose root-relative path is REL.
The first note is always the file itself."
  (let* ((case-fold-search t)
         (keywords (org-agenda-api--notes-todo-keywords))
         (preamble-end (save-excursion
                         (goto-char (point-min))
                         (if (re-search-forward "^\\*+[ \t]" nil t)
                             (line-beginning-position)
                           (point-max))))
         (keyword-value
          (lambda (name)
            (save-excursion
              (goto-char (point-min))
              (when (re-search-forward (format "^#\\+%s:[ \t]*\\(.*?\\)[ \t]*$" name) preamble-end t)
                (match-string-no-properties 1)))))
         (file-id (save-excursion
                    (goto-char (point-min))
                    (when (re-search-forward "^[ \t]*:ID:[ \t]+\\([^ \t\n]+\\)" preamble-end t)
                      (match-string-no-properties 1))))
         (title (let ((value (funcall keyword-value "title")))
                  (if (and value (not (string-empty-p value)))
                      (org-agenda-api--notes-strip-links value)
                    (file-name-base rel))))
         (file-note (org-agenda-api--note-create
                     :ref (if file-id (concat "id:" file-id) (concat "file:" rel))
                     :id file-id :file rel :title title :olp nil :level 0
                     :tags (split-string (or (funcall keyword-value "filetags") "") ":" t)))
         (notes (list file-note))
         (owners (make-hash-table :test 'eq))
         (segments (list (list file-note (point-min) preamble-end)))
         stack)
    (save-excursion
      (goto-char preamble-end)
      (let ((case-fold-search nil))
        (while (re-search-forward "^\\(\\*+\\)[ \t]+\\(.*\\)$" nil t)
          (let* ((start (line-beginning-position))
                 (level (length (match-string 1)))
                 (parsed (org-agenda-api--notes-parse-heading
                          (match-string-no-properties 2) keywords))
                 (id (org-agenda-api--notes-drawer-id)))
            (while (and stack (>= (caar stack) level))
              (pop stack))
            (let* ((owner (or (seq-some (lambda (frame) (nth 2 frame)) stack) file-note))
                   (note (when id
                           (org-agenda-api--note-create
                            :ref (concat "id:" id) :id id :file rel
                            :title (nth 0 parsed) :todo (nth 1 parsed) :tags (nth 2 parsed)
                            :level level
                            :olp (reverse (mapcar (lambda (frame) (nth 1 frame)) stack))))))
              (when note (push note notes))
              (push (list level (nth 0 parsed) note) stack)
              (setf (nth 2 (car segments)) start)
              (push (list (or note owner) start (point-max)) segments))))))
    (dolist (segment segments)
      (pcase-let ((`(,owner ,start ,end) segment))
        (puthash owner (cons (list start end) (gethash owner owners)) owners)))
    (setq notes (nreverse notes))
    (dolist (note notes)
      (let ((ranges (gethash note owners)))
        (setf (org-agenda-api--note-links note)
              (apply #'append (mapcar (lambda (range) (apply #'org-agenda-api--notes-segment-links range))
                                      ranges)))
        (setf (org-agenda-api--note-text note)
              (mapconcat (lambda (range) (apply #'buffer-substring-no-properties range))
                         ranges ""))))
    notes))

(defun org-agenda-api--notes-scan-file (path rel attributes)
  "Index the org file at PATH, whose root-relative path is REL.
ATTRIBUTES are its `file-attributes'."
  (with-temp-buffer
    (insert-file-contents path)
    (setq default-directory (file-name-directory path))
    (org-agenda-api--notes-file-create
     :path path :rel rel
     :mtime (file-attribute-modification-time attributes)
     :size (file-attribute-size attributes)
     :notes (org-agenda-api--notes-scan-buffer rel))))

(defun org-agenda-api--notes-root-files (root)
  "Return (PATH . REL) for each servable org file under ROOT."
  (let ((root (file-name-as-directory (expand-file-name root)))
        files)
    (when (file-directory-p root)
      (dolist (path (directory-files-recursively
                     root "\\.org\\'" nil
                     (lambda (dir)
                       (not (string-match-p "\\`\\(?:\\..*\\|node_modules\\)\\'"
                                            (file-name-nondirectory dir))))))
        (let ((rel (file-relative-name path root)))
          (unless (string-match-p org-agenda-api-notes-exclude-regexp rel)
            (push (cons path rel) files)))))
    files))

(defun org-agenda-api--notes-refresh ()
  "Bring the index up to date with the files on disk and return the files."
  (unless org-agenda-api-notes-directories
    (org-agenda-api--notes-fail 404 "notes_disabled" "No notes directories are configured"))
  (let ((roots org-agenda-api-notes-directories)
        (seen (make-hash-table :test 'equal)))
    (dolist (root roots)
      (let ((prefix (if (cdr roots)
                        (concat (file-name-nondirectory (directory-file-name root)) "/")
                      "")))
        (pcase-dolist (`(,path . ,rel) (org-agenda-api--notes-root-files root))
          (let* ((rel (concat prefix rel))
                 (attributes (file-attributes path))
                 (entry (gethash path org-agenda-api--notes-files)))
            (unless (and entry
                         (equal (org-agenda-api--notes-file-rel entry) rel)
                         (equal (org-agenda-api--notes-file-mtime entry)
                                (file-attribute-modification-time attributes))
                         (equal (org-agenda-api--notes-file-size entry)
                                (file-attribute-size attributes)))
              (puthash path (org-agenda-api--notes-scan-file path rel attributes)
                       org-agenda-api--notes-files))
            (puthash path t seen)))))
    (let (files)
      (maphash (lambda (path entry)
                 (if (gethash path seen)
                     (push entry files)
                   (remhash path org-agenda-api--notes-files)))
               org-agenda-api--notes-files)
      (sort files (lambda (a b)
                    (time-less-p (org-agenda-api--notes-file-mtime b)
                                 (org-agenda-api--notes-file-mtime a)))))))

;;; Index views

(cl-defstruct (org-agenda-api--notes-index
               (:constructor org-agenda-api--notes-index-create)
               (:copier nil))
  files notes by-ref by-path by-rel backlinks)

(defun org-agenda-api--notes-index ()
  "Return the refreshed index with lookup tables and backlinks."
  (let* ((files (org-agenda-api--notes-refresh))
         (by-ref (make-hash-table :test 'equal))
         (by-path (make-hash-table :test 'equal))
         (by-rel (make-hash-table :test 'equal))
         (backlinks (make-hash-table :test 'equal))
         notes)
    (dolist (file files)
      (puthash (org-agenda-api--notes-file-path file) file by-path)
      (puthash (org-agenda-api--notes-file-rel file) file by-rel)
      (dolist (note (org-agenda-api--notes-file-notes file))
        (push note notes)
        (puthash (org-agenda-api--note-ref note) note by-ref)))
    (let ((index (org-agenda-api--notes-index-create
                  :files files :notes (nreverse notes)
                  :by-ref by-ref :by-path by-path :by-rel by-rel :backlinks backlinks)))
      (dolist (source (org-agenda-api--notes-index-notes index))
        (let (targets)
          (pcase-dolist (`(,kind ,target ,context) (org-agenda-api--note-links source))
            (let ((ref (org-agenda-api--notes-link-ref index kind target)))
              (when (and ref
                         (not (equal ref (org-agenda-api--note-ref source)))
                         (not (member ref targets)))
                (push ref targets)
                (puthash ref (cons (cons source context) (gethash ref backlinks)) backlinks))))))
      (maphash (lambda (ref sources) (puthash ref (nreverse sources) backlinks)) backlinks)
      index)))

(defun org-agenda-api--notes-link-ref (index kind target)
  "Return the ref of the indexed note a KIND link to TARGET points at, or nil."
  (pcase kind
    ('id (let ((ref (concat "id:" target)))
           (and (gethash ref (org-agenda-api--notes-index-by-ref index)) ref)))
    ('file (let ((file (gethash target (org-agenda-api--notes-index-by-path index))))
             (and file (org-agenda-api--note-ref
                        (car (org-agenda-api--notes-file-notes file))))))))

(defun org-agenda-api--notes-lookup (index ref)
  "Return the note in INDEX for REF, signaling a 404 when there is none."
  (or (and (stringp ref)
           (or (gethash ref (org-agenda-api--notes-index-by-ref index))
               (and (string-prefix-p "file:" ref)
                    (let ((file (gethash (substring ref 5) (org-agenda-api--notes-index-by-rel index))))
                      (and file (car (org-agenda-api--notes-file-notes file)))))))
      (org-agenda-api--notes-fail 404 "not_found" (format "No note has ref %S" ref))))

(defun org-agenda-api--notes-file-of (index note)
  "Return the indexed file entry holding NOTE in INDEX."
  (gethash (org-agenda-api--note-file note) (org-agenda-api--notes-index-by-rel index)))

(defun org-agenda-api--notes-summary (index note)
  "Return the JSON alist summarizing NOTE in INDEX."
  (let ((file (org-agenda-api--notes-file-of index note)))
    `(("ref" . ,(org-agenda-api--note-ref note))
      ("id" . ,(org-agenda-api--note-id note))
      ("file" . ,(org-agenda-api--note-file note))
      ("fileRef" . ,(org-agenda-api--note-ref (car (org-agenda-api--notes-file-notes file))))
      ("title" . ,(org-agenda-api--note-title note))
      ("olp" . ,(vconcat (org-agenda-api--note-olp note)))
      ("level" . ,(org-agenda-api--note-level note))
      ("todo" . ,(org-agenda-api--note-todo note))
      ("tags" . ,(vconcat (org-agenda-api--note-tags note)))
      ("mtime" . ,(truncate (float-time (org-agenda-api--notes-file-mtime file))))
      ("backlinkCount" . ,(length (gethash (org-agenda-api--note-ref note)
                                           (org-agenda-api--notes-index-backlinks index)))))))

;;; Listing and search

(defun org-agenda-api--notes-snippet (text terms)
  "Return a one-line excerpt of TEXT around the first of TERMS it contains."
  (let* ((text (replace-regexp-in-string
                "[ \t\n]+" " " (org-agenda-api--notes-strip-links text)))
         (position (seq-some (lambda (term) (string-search term (downcase text))) terms)))
    (when position
      (let ((start (max 0 (- position 60)))
            (end (min (length text) (+ position 140))))
        (concat (if (> start 0) "…" "")
                (string-trim (substring text start end))
                (if (< end (length text)) "…" ""))))))

(defun org-agenda-api--notes-list (query limit)
  "Return listed notes, matching every term of QUERY when given.
Return at most LIMIT notes; nil means all of them, or a default for searches."
  (let* ((index (org-agenda-api--notes-index))
         (terms (split-string (downcase (or query "")) nil t))
         (candidates (seq-remove #'org-agenda-api--note-todo
                                 (org-agenda-api--notes-index-notes index)))
         (results
          (if (null terms)
              (mapcar (lambda (note) (cons note nil)) candidates)
            (let (title-matches body-matches)
              (dolist (note candidates)
                (let* ((title (downcase (string-join (cons (org-agenda-api--note-title note)
                                                           (org-agenda-api--note-tags note))
                                                     " ")))
                       (body (downcase (org-agenda-api--note-text note)))
                       (in-title (seq-every-p (lambda (term) (string-search term title)) terms)))
                  (cond
                   (in-title (push (cons note nil) title-matches))
                   ((seq-every-p (lambda (term) (or (string-search term title) (string-search term body)))
                                 terms)
                    (push (cons note (org-agenda-api--notes-snippet
                                      (org-agenda-api--note-text note) terms))
                          body-matches)))))
              (append (nreverse title-matches) (nreverse body-matches))))))
    `(("total" . ,(length results))
      ("notes" . ,(vconcat
                   (mapcar (lambda (result)
                             (append (org-agenda-api--notes-summary index (car result))
                                     (when (cdr result) `(("snippet" . ,(cdr result))))))
                           (seq-take results
                                     (or limit
                                         (if terms
                                             org-agenda-api-notes-default-search-limit
                                           (length results))))))))))

;;; Rendering

(defvar org-agenda-api--notes-render-index nil
  "Index used to resolve links while rendering.")

(defvar org-agenda-api--notes-render-directory nil
  "Directory of the file being rendered, for resolving relative file links.")

(defun org-agenda-api--notes-text (string soft)
  "Return STRING without properties; with SOFT, single newlines become spaces."
  (let ((string (substring-no-properties string)))
    (if soft (replace-regexp-in-string "[ \t]*\n[ \t]*" " " string) string)))

(defun org-agenda-api--notes-push-text (string inlines)
  "Push STRING onto the reversed INLINES list, merging adjacent text."
  (cond
   ((string-empty-p string) inlines)
   ((equal (cdr (assoc "t" (car inlines))) "text")
    (cons `(("t" . "text") ("v" . ,(concat (cdr (assoc "v" (car inlines))) string)))
          (cdr inlines)))
   (t (cons `(("t" . "text") ("v" . ,string)) inlines))))

(defun org-agenda-api--notes-link (link soft)
  "Return the inline alist for org-element LINK."
  (let* ((type (org-element-property :type link))
         (path (org-element-property :path link))
         (raw (org-element-property :raw-link link))
         (index org-agenda-api--notes-render-index)
         (ref (pcase type
                ("id" (org-agenda-api--notes-link-ref
                       index 'id (car (split-string path "::"))))
                ("file" (when (string-match-p "\\.org\\'" path)
                          (org-agenda-api--notes-link-ref
                           index 'file (expand-file-name path org-agenda-api--notes-render-directory))))))
         (contents (org-element-contents link)))
    `(("t" . "link")
      ("href" . ,raw)
      ("ref" . ,ref)
      ("c" . ,(if contents
                  (org-agenda-api--notes-inlines contents soft)
                (vector `(("t" . "text") ("v" . ,(if (member type '("id" "file")) path raw)))))))))

(defun org-agenda-api--notes-inlines (objects &optional soft)
  "Return org-element OBJECTS as a vector of inline alists.
With SOFT, single newlines in text are rendered as spaces."
  (let (inlines)
    (dolist (object objects)
      (if (stringp object)
          (setq inlines (org-agenda-api--notes-push-text
                         (org-agenda-api--notes-text object soft) inlines))
        (let ((inline
               (pcase (org-element-type object)
                 ((and (or 'bold 'italic 'underline 'strike-through) type)
                  `(("t" . ,(symbol-name type))
                    ("c" . ,(org-agenda-api--notes-inlines (org-element-contents object) soft))))
                 ((or 'code 'verbatim)
                  `(("t" . "code") ("v" . ,(org-element-property :value object))))
                 ('link (org-agenda-api--notes-link object soft))
                 ('timestamp
                  `(("t" . "timestamp") ("v" . ,(org-element-property :raw-value object))))
                 ('line-break "\n")
                 ('entity (org-element-property :utf-8 object))
                 ((or 'subscript 'superscript 'table-cell)
                  (org-agenda-api--notes-inlines (org-element-contents object) soft))
                 ('footnote-reference
                  (format "[%s]" (or (org-element-property :label object) "fn")))
                 ((or 'target 'radio-target)
                  (org-agenda-api--notes-inlines (org-element-contents object) soft))
                 (_ (org-agenda-api--notes-text
                     (string-trim-right (org-element-interpret-data object)) soft)))))
          (cond
           ((stringp inline)
            (setq inlines (org-agenda-api--notes-push-text inline inlines)))
           ((vectorp inline)
            (seq-doseq (child inline)
              (setq inlines (if (equal (cdr (assoc "t" child)) "text")
                                (org-agenda-api--notes-push-text (cdr (assoc "v" child)) inlines)
                              (cons child inlines)))))
           (t (push inline inlines)))
          (let ((post-blank (or (org-element-property :post-blank object) 0)))
            (when (> post-blank 0)
              (setq inlines (org-agenda-api--notes-push-text
                             (make-string post-blank ?\s) inlines)))))))
    (vconcat (nreverse inlines))))

(defun org-agenda-api--notes-trim-inlines (inlines)
  "Return INLINES with surrounding whitespace removed from edge text."
  (let ((items (append inlines nil)))
    (when (equal (cdr (assoc "t" (car items))) "text")
      (setcar items `(("t" . "text") ("v" . ,(string-trim-left (cdr (assoc "v" (car items))))))))
    (let ((last (last items)))
      (when (equal (cdr (assoc "t" (car last))) "text")
        (setcar last `(("t" . "text") ("v" . ,(string-trim-right (cdr (assoc "v" (car last)))))))))
    (vconcat (seq-remove (lambda (item) (equal item '(("t" . "text") ("v" . "")))) items))))

(defun org-agenda-api--notes-table (table)
  "Return the block alist for org-element TABLE."
  (if (eq (org-element-property :type table) 'table.el)
      `(("type" . "example") ("value" . ,(org-element-property :value table)))
    (let ((rows (org-element-contents table))
          header result)
      (let ((rule (seq-position rows 'rule
                                (lambda (row _) (eq (org-element-property :type row) 'rule)))))
        (setq header (and rule (> rule 0)
                          (seq-some (lambda (row) (eq (org-element-property :type row) 'standard))
                                    (seq-drop rows rule)))))
      (dolist (row rows)
        (when (eq (org-element-property :type row) 'standard)
          (push (vconcat (mapcar (lambda (cell)
                                   (org-agenda-api--notes-trim-inlines
                                    (org-agenda-api--notes-inlines (org-element-contents cell) t)))
                                 (org-element-contents row)))
                result)))
      `(("type" . "table")
        ("header" . ,(if header t :json-false))
        ("rows" . ,(vconcat (nreverse result)))))))

(defun org-agenda-api--notes-block (element)
  "Return ELEMENT as a block alist, a list of block alists, or nil to skip it."
  (pcase (org-element-type element)
    ('paragraph
     (let ((content (org-agenda-api--notes-trim-inlines
                     (org-agenda-api--notes-inlines (org-element-contents element) t))))
       (when (> (length content) 0)
         `(("type" . "paragraph") ("content" . ,content)))))
    ('verse-block
     `(("type" . "verse")
       ("content" . ,(org-agenda-api--notes-trim-inlines
                      (org-agenda-api--notes-inlines (org-element-contents element))))))
    ('plain-list
     `(("type" . "list")
       ("ordered" . ,(if (eq (org-element-property :type element) 'ordered) t :json-false))
       ("items" . ,(vconcat
                    (mapcar
                     (lambda (item)
                       `(("checkbox" . ,(pcase (org-element-property :checkbox item)
                                          ('on "on") ('off "off") ('trans "trans") (_ nil)))
                         ("tag" . ,(let ((tag (org-element-property :tag item)))
                                     (and tag (org-agenda-api--notes-inlines tag t))))
                         ("blocks" . ,(org-agenda-api--notes-blocks (org-element-contents item)))))
                     (org-element-contents element))))))
    ('src-block
     `(("type" . "src")
       ("language" . ,(org-element-property :language element))
       ("value" . ,(string-trim-right (org-element-property :value element)))))
    ((or 'example-block 'fixed-width 'export-block 'latex-environment)
     `(("type" . "example")
       ("value" . ,(string-trim-right (or (org-element-property :value element) "")))))
    ('quote-block
     `(("type" . "quote") ("blocks" . ,(org-agenda-api--notes-blocks (org-element-contents element)))))
    ('table (org-agenda-api--notes-table element))
    ('horizontal-rule '(("type" . "rule")))
    ('planning
     `(("type" . "planning") ("text" . ,(string-trim (org-element-interpret-data element)))))
    ('footnote-definition
     `(("type" . "footnote")
       ("label" . ,(org-element-property :label element))
       ("blocks" . ,(org-agenda-api--notes-blocks (org-element-contents element)))))
    ('drawer
     (unless (member (org-element-property :drawer-name element) '("LOGBOOK" "PROPERTIES"))
       (append (org-agenda-api--notes-blocks (org-element-contents element)) nil)))
    ((or 'section 'center-block 'special-block 'dynamic-block)
     (append (org-agenda-api--notes-blocks (org-element-contents element)) nil))
    ((or 'keyword 'property-drawer 'clock 'comment 'comment-block 'babel-call 'diary-sexp)
     nil)
    (_ `(("type" . "example")
         ("value" . ,(string-trim-right (org-element-interpret-data element)))))))

(defun org-agenda-api--notes-blocks (elements)
  "Return the non-heading ELEMENTS as a vector of block alists."
  (let (blocks)
    (dolist (element elements)
      (unless (eq (org-element-type element) 'headline)
        (let ((block (org-agenda-api--notes-block element)))
          (cond
           ((null block))
           ((stringp (caar block)) (push block blocks))
           (t (setq blocks (append (reverse block) blocks)))))))
    (vconcat (nreverse blocks))))

(defun org-agenda-api--notes-heading (headline)
  "Return org-element HEADLINE and its subheadings as a heading alist."
  (let ((id (org-element-property :ID headline))
        (priority (org-element-property :priority headline)))
    `(("level" . ,(org-element-property :level headline))
      ("title" . ,(org-agenda-api--notes-trim-inlines
                   (org-agenda-api--notes-inlines (org-element-property :title headline) t)))
      ("todo" . ,(org-element-property :todo-keyword headline))
      ("priority" . ,(and priority (char-to-string priority)))
      ("tags" . ,(vconcat (org-element-property :tags headline)))
      ("ref" . ,(and id (concat "id:" id)))
      ,@(org-agenda-api--notes-content (org-element-contents headline)))))

(defun org-agenda-api--notes-content (elements)
  "Return the blocks and child headings among ELEMENTS as alist entries."
  `(("blocks" . ,(org-agenda-api--notes-blocks elements))
    ("children" . ,(vconcat
                    (mapcar #'org-agenda-api--notes-heading
                            (seq-filter (lambda (element) (eq (org-element-type element) 'headline))
                                        elements))))))

(defun org-agenda-api--notes-render (index note)
  "Return the content of NOTE in INDEX as an alist with blocks and children."
  (let ((file (org-agenda-api--notes-file-of index note))
        (id (org-agenda-api--note-id note)))
    (with-temp-buffer
      (insert-file-contents (org-agenda-api--notes-file-path file))
      (let ((org-inhibit-startup t)
            (org-element-use-cache nil))
        (delay-mode-hooks (org-mode))
        (when (and id (> (org-agenda-api--note-level note) 0))
          (goto-char (point-min))
          (unless (re-search-forward
                   (format "^[ \t]*:ID:[ \t]+%s[ \t]*$" (regexp-quote id)) nil t)
            (org-agenda-api--notes-fail 404 "not_found" "The note changed on disk; try again"))
          (org-back-to-heading t)
          (narrow-to-region (point) (save-excursion (org-end-of-subtree t t) (point))))
        (let* ((org-agenda-api--notes-render-index index)
               (org-agenda-api--notes-render-directory
                (file-name-directory (org-agenda-api--notes-file-path file)))
               (data (org-element-contents (org-element-parse-buffer 'object))))
          (if (> (org-agenda-api--note-level note) 0)
              (org-agenda-api--notes-content (org-element-contents (car data)))
            (org-agenda-api--notes-content data)))))))

(defun org-agenda-api--notes-get (ref)
  "Return the full response for the note with REF."
  (let* ((index (org-agenda-api--notes-index))
         (note (org-agenda-api--notes-lookup index ref))
         (summary (lambda (other &optional context)
                    (append (org-agenda-api--notes-summary index other)
                            (when context `(("context" . ,context))))))
         (outgoing nil))
    (pcase-dolist (`(,kind ,target ,_) (org-agenda-api--note-links note))
      (let ((target-ref (org-agenda-api--notes-link-ref index kind target)))
        (when (and target-ref (not (member target-ref outgoing))
                   (not (equal target-ref (org-agenda-api--note-ref note))))
          (push target-ref outgoing))))
    `(("note" . ,(funcall summary note))
      ("content" . ,(org-agenda-api--notes-render index note))
      ("links" . ,(vconcat (mapcar (lambda (target-ref)
                                     (funcall summary (gethash target-ref (org-agenda-api--notes-index-by-ref index))))
                                   (nreverse outgoing))))
      ("backlinks" . ,(vconcat (mapcar (lambda (backlink) (funcall summary (car backlink) (cdr backlink)))
                                       (gethash (org-agenda-api--note-ref note)
                                                (org-agenda-api--notes-index-backlinks index))))))))

;;; Endpoints

(defun org-agenda-api--notes-limit (query)
  "Read the limit parameter from QUERY, or nil when it is absent."
  (let ((value (cadr (assoc "limit" query))))
    (cond
     ((null value) nil)
     ((and (string-match-p "\\`[0-9]+\\'" value)
           (<= 1 (string-to-number value) org-agenda-api-notes-max-limit))
      (string-to-number value))
     (t (org-agenda-api--notes-fail
         400 "invalid_query_parameter"
         (format "Query parameter 'limit' must be an integer from 1 to %d"
                 org-agenda-api-notes-max-limit))))))

(defmacro org-agenda-api--notes-respond (endpoint &rest body)
  "Insert the JSON encoding of BODY's value, reporting errors for ENDPOINT."
  (declare (indent 1))
  `(progn
     (condition-case err
         (insert (json-encode (progn ,@body)))
       (org-agenda-api-notes-error
        (pcase-let ((`(,status ,code ,message) (cdr err)))
          (insert (json-encode `(("status" . "error") ("code" . ,code) ("message" . ,message))))
          (httpd-send-header t "application/json; charset=utf-8" status)))
       (error
        (org-agenda-api--log-error-with-backtrace ,endpoint err)
        (insert (json-encode `(("status" . "error")
                               ("code" . "internal_error")
                               ("message" . ,(error-message-string err)))))
        (httpd-send-header t "application/json; charset=utf-8" 500)))
     (org-agenda-api--track-request)))

(defservlet notes application/json (_path query)
  "Endpoint: list or search notes; see `org-agenda-api-notes-directories'."
  (org-agenda-api--notes-respond "/notes"
    (org-agenda-api--notes-list (cadr (assoc "q" query)) (org-agenda-api--notes-limit query))))

(defservlet note application/json (_path query)
  "Endpoint: one note's content, links and backlinks by ref."
  (org-agenda-api--notes-respond "/note"
    (let ((ref (cadr (assoc "ref" query))))
      (unless ref
        (org-agenda-api--notes-fail 400 "missing_ref" "Query parameter 'ref' is required"))
      (org-agenda-api--notes-get ref))))

(provide 'org-agenda-api-notes)
;;; org-agenda-api-notes.el ends here
