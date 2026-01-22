# org-agenda-api Module Split Design

## Goals

- **Maintainability**: Break up 2600-line monolith into navigable modules
- **Optional features**: Allow loading core without category strategies or window-habit
- **Packaging**: Clear separation of concerns
- **Testing**: Cleaner unit boundaries for testing individual components
- **AI browsability**: Intuitive file structure for agent navigation

## Module Structure

```
org-agenda-api/
├── org-agenda-api.el            # Facade - requires all, exports public API
├── org-agenda-api-core.el       # Logging, caching, config, shared utilities
├── org-agenda-api-data.el       # Data extraction from org entries
├── org-agenda-api-endpoints.el  # HTTP endpoints (defservlets)
├── org-agenda-api-capture.el    # Capture template functionality
├── org-agenda-api-categories.el # Category strategy support (optional)
├── org-agenda-api-window-habit.el # Window habit integration (optional, exists)
```

## Dependency Graph

```
org-agenda-api (facade)
    ├── org-agenda-api-endpoints
    │       ├── org-agenda-api-data
    │       │       └── org-agenda-api-core
    │       └── org-agenda-api-capture
    │               └── org-agenda-api-core
    ├── org-agenda-api-categories (optional)
    │       ├── org-agenda-api-data
    │       └── org-agenda-api-core
    └── org-agenda-api-window-habit (optional)
            └── org-agenda-api-core
```

## Module Contents

### org-agenda-api-core.el

Foundation that everything else builds on.

**Logging**
- `org-agenda-api-log-level` customization
- `org-agenda-api--log`, `org-agenda-api--log-request`, `org-agenda-api--log-response`
- `org-agenda-api--log-error`, `org-agenda-api--log-error-with-backtrace`
- `org-agenda-api--capture-backtrace`

**Configuration**
- All `defcustom` definitions: `org-agenda-api-port`, `org-agenda-api-host`, `org-agenda-api-cache-ttl`, `org-agenda-api-max-requests`, `org-agenda-api-max-lifetime`, `org-agenda-api-git-repos`, `org-agenda-api-capture-templates`, `org-agenda-api-category-strategies`
- `org-agenda-api-version` constant

**Caching**
- `org-agenda-api--cache`, `org-agenda-api--cache-times`
- `org-agenda-api--cache-get`, `org-agenda-api--cache-set`, `org-agenda-api--cache-invalidate`

**Worker lifecycle**
- `org-agenda-api--request-count`, `org-agenda-api--start-time`
- `org-agenda-api--track-request`, `org-agenda-api--should-restart`

**Git refresh**
- `org-agenda-api--git-pull-repo`, `org-agenda-api--refresh-git-repos`

### org-agenda-api-data.el

Data extraction from org entries. No HTTP concerns.

**Timestamp handling**
- `org-agenda-api--format-timestamp`
- `org-agenda-api--parse-iso-date`, `org-agenda-api--parse-time-string`
- `org-agenda-api--get-entry-timestamps`
- `org-agenda-api--timestamp-has-time-p`

**Planning info extraction**
- `org-agenda-api--get-planning-info`

**Entry data extraction**
- `org-agenda-api--get-all-entry-properties`
- `org-agenda-api--get-todo-entry-at-point`

**Agenda traversal**
- `org-agenda-api--collect-todos`, `org-agenda-api--collect-agenda-entries`
- `org-agenda-api--map-agenda-files`

**Lenient heading matching**
- `org-agenda-api--find-heading-lenient`
- All fuzzy matching helpers

**Logbook parsing**
- `org-agenda-api--parse-logbook`

### org-agenda-api-capture.el

Capture template functionality.

**Template management**
- `org-agenda-api--get-merged-templates`
- `org-agenda-api--template-to-json`
- `org-agenda-api--list-templates`

**Capture execution**
- `org-agenda-api--do-capture`
- `org-agenda-api--build-capture-template`

**Entry insertion utilities**
- `org-agenda-api--insert-planning-line`
- `org-agenda-api--insert-properties`
- `org-agenda-api--add-tags-to-heading`

### org-agenda-api-endpoints.el

All `defservlet` definitions. Pure HTTP layer.

**Query endpoints**
- `/get-all-todos`, `/agenda`, `/get-todays-agenda`
- `/agenda-files`, `/todo-states`, `/custom-views`, `/custom-view`
- `/templates`

**Mutation endpoints**
- `/capture`, `/update`, `/complete`, `/delete`

**Utility endpoints**
- `/health`, `/version`, `/debug-config`, `/restart`

### org-agenda-api-categories.el

Optional category strategy support. Only needed with org-project-capture.

**Strategy helpers**
- `org-agenda-api--parse-strategy-entry`
- `org-agenda-api--get-strategy`, `org-agenda-api--get-strategy-template`, `org-agenda-api--get-strategy-prompts`
- `org-agenda-api--list-category-types`

**Category data access**
- `org-agenda-api--get-categories-for-strategy`
- `org-agenda-api--get-existing-categories-for-strategy`
- `org-agenda-api--get-todo-files-for-strategy`
- `org-agenda-api--get-tasks-for-category`

**Category endpoints**
- `/category-types`, `/categories`, `/category-tasks`, `/category-capture`

### org-agenda-api-window-habit.el

Already exists as separate file. No changes needed.

### org-agenda-api.el (Facade)

Thin file that ties everything together:

```elisp
(require 'org-agenda-api-core)
(require 'org-agenda-api-data)
(require 'org-agenda-api-capture)
(require 'org-agenda-api-endpoints)

;; Optional features - load if dependencies available
(require 'org-agenda-api-categories nil t)
(require 'org-agenda-api-window-habit nil t)

;;;###autoload
(defun org-agenda-api-start () ...)

;;;###autoload
(defun org-agenda-api-stop () ...)

(provide 'org-agenda-api)
```

## Implementation Notes

- Each module provides its own feature symbol (e.g., `org-agenda-api-core`)
- Optional modules use soft requires: `(require 'org-agenda-api-categories nil t)`
- Category functions check `fboundp` before calling `occ-*` functions
- Package-Requires header stays in facade file
- Version constant stays in core, read by facade
