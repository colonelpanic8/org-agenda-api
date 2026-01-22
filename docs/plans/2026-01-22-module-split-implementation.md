# Module Split Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Split org-agenda-api.el (2610 lines) into focused modules for maintainability, optional feature loading, and AI browsability.

**Architecture:** Bottom-up extraction starting with core (no dependencies), then data layer, then capture, then endpoints, then categories. Each module provides its own feature symbol. The facade requires all modules.

**Tech Stack:** Emacs Lisp, simple-httpd

---

## Task 1: Create org-agenda-api-core.el

**Files:**
- Create: `org-agenda-api-core.el`

**Step 1: Create the file with header and requires**

Create `org-agenda-api-core.el` with standard elisp header, requiring `cl-lib`:

```elisp
;;; org-agenda-api-core.el --- Core utilities for org-agenda-api -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison
;; Author: Ivan Malison <IvanMalison@gmail.com>

;;; Commentary:
;; Core utilities: logging, caching, configuration, git refresh, worker lifecycle.

;;; Code:

(require 'cl-lib)
```

**Step 2: Extract version constant (lines 72-80)**

Copy from org-agenda-api.el:
- `org-agenda-api-version` defconst

Note: Version reading requires `lisp-mnt`, add that require.

**Step 3: Extract logging (lines 82-150)**

Copy from org-agenda-api.el:
- `org-agenda-api-log-level` defcustom
- `org-agenda-api--log`
- `org-agenda-api--log-request`
- `org-agenda-api--log-response`
- `org-agenda-api--log-error`
- `org-agenda-api--capture-backtrace`
- `org-agenda-api--log-error-with-backtrace`

**Step 4: Extract customization (lines 151-225)**

Copy from org-agenda-api.el:
- `org-agenda-api` defgroup
- `org-agenda-api-port` defcustom
- `org-agenda-api-capture-templates` defcustom
- `org-agenda-api-max-requests` defcustom
- `org-agenda-api-max-lifetime` defcustom
- `org-agenda-api-category-strategies` defcustom

**Step 5: Extract worker lifecycle (lines 226-332)**

Copy from org-agenda-api.el:
- `org-agenda-api--request-count` defvar
- `org-agenda-api--start-time` defvar
- `org-agenda-api--check-worker-lifecycle`
- `org-agenda-api--track-request`

**Step 6: Extract caching (lines 234-265)**

Copy from org-agenda-api.el:
- `org-agenda-api--todos-cache` defvar
- `org-agenda-api--cache-mtime` defvar
- `org-agenda-api--get-max-mtime`
- `org-agenda-api--cache-valid-p`
- `org-agenda-api--invalidate-cache`

Note: `org-agenda-api--get-max-mtime` uses `org-agenda-files`, need to require `org-agenda`.

**Step 7: Extract git refresh (lines 266-303)**

Copy from org-agenda-api.el:
- `org-agenda-api--get-git-repos-for-agenda-files`
- `org-agenda-api--git-refresh-repo`
- `org-agenda-api--git-refresh-all`

**Step 8: Extract utility functions (lines 333-345)**

Copy from org-agenda-api.el:
- `org-agenda-api--plist-to-alist`

**Step 9: Add provide statement**

```elisp
(provide 'org-agenda-api-core)
;;; org-agenda-api-core.el ends here
```

**Step 10: Commit**

```bash
git add org-agenda-api-core.el
git commit -m "feat: create org-agenda-api-core.el with logging, caching, config"
```

---

## Task 2: Create org-agenda-api-data.el

**Files:**
- Create: `org-agenda-api-data.el`

**Step 1: Create the file with header and requires**

```elisp
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
```

**Step 2: Extract timestamp handling (lines 348-439)**

Copy from org-agenda-api.el:
- `org-agenda-api--parse-notify-before`
- `org-agenda-api--timestamp-to-time`
- `org-agenda-api--timestamp-end-to-time`
- `org-agenda-api--get-planning-info`
- `org-agenda-api--format-timestamp`
- `org-agenda-api--extract-date`
- `org-agenda-api--deduplicate-entries`

**Step 3: Extract property and logbook functions (lines 455-607)**

Copy from org-agenda-api.el:
- `org-agenda-api--get-all-entry-properties`
- `org-agenda-api--get-logbook-entries`
- `org-agenda-api--parse-inactive-timestamp`
- `org-agenda-api--format-timestamp-element`
- `org-agenda-api--get-entry-timestamps`

**Step 4: Extract agenda traversal functions (lines 608-990)**

Copy from org-agenda-api.el:
- `org-agenda-api--get-todo-elements-from-filepath`
- `org-agenda-api--get-agenda-todos`
- `org-agenda-api--element-to-json`
- `org-agenda-api--item-to-json`
- `org-agenda-api--get-scheduled-or-deadlined`
- `org-agenda-api--get-today-agenda`
- `org-agenda-api--get-closed-timestamp`
- `org-agenda-api--extract-entry-data`
- `org-agenda-api--run-agenda`

**Step 5: Extract custom view functions (lines 991-1046)**

Copy from org-agenda-api.el:
- `org-agenda-api--list-custom-views`
- `org-agenda-api--run-custom-view`
- `org-agenda-api--get-custom-view-name`
- `org-agenda-api--cleanup-emacs-state`

**Step 6: Extract lenient heading matching (lines 1640-1750)**

Copy from org-agenda-api.el:
- `org-agenda-api--normalize-string`
- `org-agenda-api--string-match-lenient`
- `org-agenda-api--find-todo-by-id`
- `org-agenda-api--find-todo-by-file-pos-title`
- `org-agenda-api--find-todo-by-file-title`
- `org-agenda-api--find-todo-by-title`

**Step 7: Extract date/time parsing utilities (lines 1749-1780)**

Copy from org-agenda-api.el:
- `org-agenda-api--datetime-has-time-p`
- `org-agenda-api--parse-datetime`
- `org-agenda-api--format-org-timestamp`

**Step 8: Extract todo state and filter functions (lines 1451-1521)**

Copy from org-agenda-api.el:
- `org-agenda-api--get-todo-states`
- `org-agenda-api--get-filter-options`
- `org-agenda-api--get-default-notify-before`

**Step 9: Add provide statement**

```elisp
(provide 'org-agenda-api-data)
;;; org-agenda-api-data.el ends here
```

**Step 10: Commit**

```bash
git add org-agenda-api-data.el
git commit -m "feat: create org-agenda-api-data.el with data extraction functions"
```

---

## Task 3: Create org-agenda-api-capture.el

**Files:**
- Create: `org-agenda-api-capture.el`

**Step 1: Create the file with header and requires**

```elisp
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
```

**Step 2: Extract capture template functions (lines 1066-1295)**

Copy from org-agenda-api.el:
- `org-agenda-api--get-default-capture-target`
- `org-agenda-api--make-default-template`
- `org-agenda-api--get-template`
- `org-agenda-api--template-to-json`
- `org-agenda-api--get-all-templates-json`
- `org-agenda-api--current-capture-values` defvar
- `org-agenda-api--validate-capture-values`
- `org-agenda-api--format-tags`
- `org-agenda-api--format-date`
- `org-agenda-api--format-inactive-timestamp`
- `org-agenda-api--build-entry-from-template`
- `org-agenda-api--capture-with-template`

**Step 3: Extract capture readiness check (lines 1398-1411)**

Copy from org-agenda-api.el:
- `org-agenda-api--check-capture-ready`

**Step 4: Add provide statement**

```elisp
(provide 'org-agenda-api-capture)
;;; org-agenda-api-capture.el ends here
```

**Step 5: Commit**

```bash
git add org-agenda-api-capture.el
git commit -m "feat: create org-agenda-api-capture.el with capture template functions"
```

---

## Task 4: Create org-agenda-api-mutations.el

**Files:**
- Create: `org-agenda-api-mutations.el`

Note: Splitting mutations out separately since they're substantial and distinct from read endpoints.

**Step 1: Create the file with header and requires**

```elisp
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
```

**Step 2: Extract complete function (lines 1716-1747)**

Copy from org-agenda-api.el:
- `org-agenda-api--complete-todo-at`

**Step 3: Extract update function (lines 1781-1892)**

Copy from org-agenda-api.el:
- `org-agenda-api--update-todo-at`

**Step 4: Extract delete functions (lines 2044-2145)**

Copy from org-agenda-api.el:
- `org-agenda-api--delete-error`
- `org-agenda-api--delete-item`

**Step 5: Add provide statement**

```elisp
(provide 'org-agenda-api-mutations)
;;; org-agenda-api-mutations.el ends here
```

**Step 6: Commit**

```bash
git add org-agenda-api-mutations.el
git commit -m "feat: create org-agenda-api-mutations.el with complete, update, delete"
```

---

## Task 5: Create org-agenda-api-endpoints.el

**Files:**
- Create: `org-agenda-api-endpoints.el`

**Step 1: Create the file with header and requires**

```elisp
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
```

**Step 2: Extract query endpoints**

Copy from org-agenda-api.el:
- `defservlet get-all-todos` (line 1307)
- `defservlet get-todays-agenda` (line 1323)
- `defservlet agenda` (line 1330)
- `defservlet capture-templates` (line 1361)
- `defservlet todo-states` (line 1523)
- `defservlet filter-options` (line 1529)
- `defservlet agenda-files` (line 1547)
- `defservlet custom-views` (line 1560)
- `defservlet metadata` (line 1574)
- `defservlet custom-view` (line 1609)

**Step 3: Extract mutation endpoints**

Copy from org-agenda-api.el:
- `defservlet capture` (line 1376)
- `defservlet update` (line 1893)
- `defservlet complete` (line 1996)
- `defservlet delete` (line 2146)

**Step 4: Extract utility endpoints**

Copy from org-agenda-api.el:
- `defservlet health` (line 1413)
- `defservlet version` (line 1431)
- `defservlet debug-config` (line 1440)
- `defservlet restart` (line 1631)

**Step 5: Add provide statement**

```elisp
(provide 'org-agenda-api-endpoints)
;;; org-agenda-api-endpoints.el ends here
```

**Step 6: Commit**

```bash
git add org-agenda-api-endpoints.el
git commit -m "feat: create org-agenda-api-endpoints.el with all defservlets"
```

---

## Task 6: Create org-agenda-api-categories.el

**Files:**
- Create: `org-agenda-api-categories.el`

**Step 1: Create the file with header and requires**

```elisp
;;; org-agenda-api-categories.el --- Category strategy support for org-agenda-api -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison
;; Author: Ivan Malison <IvanMalison@gmail.com>

;;; Commentary:
;; Optional category strategy support for org-project-capture integration.
;; This module can be loaded optionally when org-category-capture is available.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'json)
(require 'simple-httpd)
(require 'org-agenda-api-core)
(require 'org-agenda-api-data)
```

**Step 2: Extract category helper functions (lines 2202-2338)**

Copy from org-agenda-api.el:
- `org-agenda-api--default-category-prompts` defvar
- `org-agenda-api--parse-strategy-entry`
- `org-agenda-api--get-strategy`
- `org-agenda-api--get-strategy-template`
- `org-agenda-api--get-strategy-prompts`
- `org-agenda-api--list-category-types`
- `org-agenda-api--get-categories-for-strategy`
- `org-agenda-api--get-existing-categories-for-strategy`
- `org-agenda-api--get-todo-files-for-strategy`
- `org-agenda-api--get-tasks-for-category`

**Step 3: Extract category capture functions (lines 2432-2518)**

Copy from org-agenda-api.el:
- `org-agenda-api--build-category-capture-template`
- `org-agenda-api--capture-to-category`

**Step 4: Extract category endpoints (lines 2339-2577)**

Copy from org-agenda-api.el:
- `defservlet category-types` (line 2339)
- `defservlet categories` (line 2372)
- `defservlet category-tasks` (line 2401)
- `defservlet category-capture` (line 2519)

**Step 5: Add provide statement**

```elisp
(provide 'org-agenda-api-categories)
;;; org-agenda-api-categories.el ends here
```

**Step 6: Commit**

```bash
git add org-agenda-api-categories.el
git commit -m "feat: create org-agenda-api-categories.el with category strategy support"
```

---

## Task 7: Refactor org-agenda-api.el into facade

**Files:**
- Modify: `org-agenda-api.el`

**Step 1: Strip org-agenda-api.el down to facade**

Replace entire contents with:

```elisp
;;; org-agenda-api.el --- JSON HTTP API for org-agenda -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ivan Malison

;; Author: Ivan Malison <IvanMalison@gmail.com>
;; URL: https://github.com/IvanMalison/org-agenda-api
;; Version: 2.2.1
;; Package-Requires: ((emacs "26.1") (simple-httpd "1.5.1"))
;; Keywords: org, agenda, api, json

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides a JSON HTTP API for accessing org-agenda data.
;; It exposes endpoints for retrieving todos and scheduled items.
;;
;; Usage:
;;   (require 'org-agenda-api)
;;   (org-agenda-api-start)
;;
;; For API documentation, see README.md

;;; Code:

;; Required modules
(require 'org-agenda-api-core)
(require 'org-agenda-api-data)
(require 'org-agenda-api-capture)
(require 'org-agenda-api-mutations)
(require 'org-agenda-api-endpoints)

;; Optional modules - load if dependencies available
(require 'org-agenda-api-categories nil t)
(require 'org-agenda-api-window-habit nil t)

;;; Public API

(defun org-agenda-api--warm-cache ()
  "Pre-populate the TODO cache for faster first requests."
  (message "org-agenda-api: Warming cache for %d files..." (length org-agenda-files))
  (let ((start-time (current-time)))
    (org-agenda-api--get-agenda-todos)
    (message "org-agenda-api: Cache warmed in %.2fs (%d items)"
             (float-time (time-subtract (current-time) start-time))
             (length org-agenda-api--todos-cache))))

;;;###autoload
(defun org-agenda-api-start ()
  "Start the org-agenda-api HTTP server."
  (interactive)
  (setq httpd-port org-agenda-api-port)
  (setq org-agenda-api--start-time (current-time))
  (setq org-agenda-api--request-count 0)
  ;; Warm cache before starting server
  (org-agenda-api--warm-cache)
  (httpd-start)
  (message "org-agenda-api: HTTP server started on port %d" org-agenda-api-port))

;;;###autoload
(defun org-agenda-api-stop ()
  "Stop the org-agenda-api HTTP server."
  (interactive)
  (httpd-stop)
  (message "org-agenda-api: HTTP server stopped"))

(provide 'org-agenda-api)
;;; org-agenda-api.el ends here
```

**Step 2: Commit**

```bash
git add org-agenda-api.el
git commit -m "refactor: convert org-agenda-api.el to facade module"
```

---

## Task 8: Update org-agenda-api-window-habit.el

**Files:**
- Modify: `org-agenda-api-window-habit.el`

**Step 1: Update requires to use org-agenda-api-core**

Change the require from `org-agenda-api` to `org-agenda-api-core` (for logging, config) and any other needed modules.

**Step 2: Commit**

```bash
git add org-agenda-api-window-habit.el
git commit -m "refactor: update org-agenda-api-window-habit.el requires"
```

---

## Task 9: Run tests and fix any issues

**Step 1: Run the test suite**

```bash
cd /home/imalison/dotfiles/dotfiles/emacs.d/straight/repos/org-agenda-api/.worktrees/module-split
pytest tests/ -v
```

**Step 2: Fix any require ordering or missing function issues**

The tests spin up a real Emacs server, so they'll catch any require issues.

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve module dependency issues from split"
```

---

## Task 10: Update flake.nix to include new files

**Files:**
- Modify: `flake.nix`

**Step 1: Check if flake.nix copies specific files**

Look for any hardcoded file references that need updating.

**Step 2: Update if needed and commit**

```bash
git add flake.nix
git commit -m "build: update flake.nix for new module structure"
```

---

## Task 11: Delete stale .elc files and update .gitignore

**Step 1: Remove any stale .elc files**

```bash
rm -f org-agenda-api-*.elc
```

**Step 2: Ensure .elc files are gitignored**

Add `*.elc` to `.gitignore` if not present.

**Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: clean up stale elc files"
```

---

## Summary

After completing all tasks, the module structure will be:

| File | Lines (approx) | Purpose |
|------|----------------|---------|
| org-agenda-api-core.el | ~280 | Logging, caching, config, git refresh |
| org-agenda-api-data.el | ~700 | Data extraction, timestamps, agenda traversal |
| org-agenda-api-capture.el | ~230 | Capture template management |
| org-agenda-api-mutations.el | ~200 | Complete, update, delete operations |
| org-agenda-api-endpoints.el | ~400 | HTTP endpoint definitions |
| org-agenda-api-categories.el | ~380 | Category strategy support (optional) |
| org-agenda-api-window-habit.el | ~200 | Window habit integration (optional) |
| org-agenda-api.el | ~80 | Facade with public API |

Total: ~2470 lines across 8 files (vs 2610 in monolith, slight reduction from header deduplication)
