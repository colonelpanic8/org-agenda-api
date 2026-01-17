# Tags Support Design

## Overview

Add support for updating tags via the `/update` endpoint. Tags are already included in API outputs (todos, agenda entries); this adds the ability to modify them.

## API Changes

### `/update` Endpoint

New `tags` field in request body:

```json
{
  "id": "some-org-id",
  "tags": ["work", "urgent", "project-x"]
}
```

**Behavior:**
- `tags: ["a", "b"]` - Sets tags to exactly `:a:b:`
- `tags: []` - Clears all tags
- `tags: null` or field omitted - No change to tags

**Response** includes applied tags:
```json
{
  "status": "updated",
  "title": "Task title",
  "file": "/path/to/file.org",
  "pos": 1234,
  "updates": [["tags", ["work", "urgent"]]]
}
```

## Implementation

### Elisp Changes (`org-agenda-api.el`)

Add tags handling in `org-agenda-api--update-todo-at` after priority handling:

```elisp
;; Handle tags
(when (assoc "tags" updates)
  (let ((tags-value (cdr (assoc "tags" updates))))
    (if (or (null tags-value) (eq tags-value :json-null))
        nil  ; null means no change
      (let ((tag-list (if (vectorp tags-value)
                          (append tags-value nil)
                        tags-value)))
        (org-set-tags tag-list)
        (push `("tags" . ,(vconcat tag-list)) applied-updates)))))
```

Update docstrings to document the `tags` parameter.

## Test Plan

New test file: `test_update_tags.py`

1. Set tags on item with no tags
2. Replace existing tags
3. Clear all tags with empty array
4. Verify null/omitted tags causes no change
5. Combined update (tags + priority + scheduled)
6. Verify tags in re-fetched todo data
7. Verify tags appear in `/agenda` output
