# Delete Endpoint Design

## Overview

Add a `/delete` endpoint to permanently remove TODO items/headlines from org files.

## Endpoint Interface

**Endpoint:** `POST /delete`

**Request body:**
```json
{
  "id": "org-id-abc123",           // Option 1: org-id
  // OR
  "file": "/path/to/file.org",    // Option 2: file + position
  "position": 1234,

  "include_children": false        // Required true if item has children
}
```

**Behavior:**
- If item has no children: deletes immediately
- If item has children and `include_children` is `false` or missing: returns error with child count
- If item has children and `include_children` is `true`: deletes entire subtree

**Success response:**
```json
{
  "deleted": true,
  "title": "The deleted item's title",
  "children_deleted": 3            // Only present if children were deleted
}
```

**Error response (has children):**
```json
{
  "error": "Item has 3 children. Set include_children=true to delete subtree."
}
```

## Implementation

**New function:** `org-agenda-api--delete-item`

**Logic flow:**
1. Locate the item:
   - If `id` provided: use `org-id-find` to get file and position
   - If `file` + `position` provided: use directly
2. Navigate to the headline at that position
3. Count children using `org-map-entries` within the subtree
4. If children exist and `include_children` is false: return error
5. Delete using `org-cut-subtree` (removes headline and all content)
6. Save the buffer
7. Return success response with item title

**Key org-mode functions:**
- `org-id-find` - locate by org-id
- `org-at-heading-p` - verify we're at a headline
- `org-end-of-subtree` - find subtree boundaries
- `org-cut-subtree` - delete the headline and contents
- `org-get-heading` - get title for response

## Error Handling

| Condition | Response |
|-----------|----------|
| Item not found (invalid id or position) | `{"error": "Item not found"}` |
| Position doesn't point to a headline | `{"error": "Position is not at a headline"}` |
| File doesn't exist | `{"error": "File not found: /path/to/file.org"}` |
| File not in agenda files | `{"error": "File is not an agenda file"}` |
| Has children without confirmation | `{"error": "Item has N children. Set include_children=true to delete subtree."}` |

## Edge Cases

- Narrowed buffers: widen before operating
- Unsaved changes: save after deletion
- Cache invalidation: trigger cache refresh after delete

## Security

Only allow deleting from files in `org-agenda-files` to prevent arbitrary file modification.

## Integration

- Add `org-agenda-api--handle-delete` to httpd routes
- Follow existing patterns from `/update` and `/complete` endpoints
- Cache invalidation on success (same as other mutation endpoints)
