# Delete Endpoint Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add POST /delete endpoint to permanently remove org items from agenda files.

**Architecture:** Implement `org-agenda-api--delete-item` function that locates items by org-id or file+position, counts children for safety confirmation, then uses `org-cut-subtree` to delete. Register as httpd servlet following existing `/update` and `/complete` patterns.

**Tech Stack:** Emacs Lisp, simple-httpd, org-mode APIs

---

## Task 1: Write Basic Delete Test

**Files:**
- Create: `tests/test_delete.py`

**Step 1: Write the failing test for basic delete**

```python
"""Integration tests for POST /delete endpoint."""

import pytest


class TestDeleteTodo:
    """Tests for POST /delete endpoint."""

    def test_returns_200_on_success(self, api):
        """Endpoint should return 200 OK on successful delete."""
        # Create a todo to delete
        api.create_todo("Delete me please")

        # Find it
        todos = api.get_all_todos().json()["todos"]
        todo = next((t for t in todos if "Delete me please" in t.get("title", "")), None)
        assert todo is not None, "Failed to create test todo"

        # Delete it
        response = api.post("/delete", json={
            "file": todo["file"],
            "position": todo["pos"]
        })
        assert response.status_code == 200

    def test_returns_deleted_title(self, api):
        """Response should include the deleted item's title."""
        api.create_todo("Title for deletion test")

        todos = api.get_all_todos().json()["todos"]
        todo = next((t for t in todos if "Title for deletion test" in t.get("title", "")), None)
        assert todo is not None

        response = api.post("/delete", json={
            "file": todo["file"],
            "position": todo["pos"]
        })
        data = response.json()

        assert data.get("deleted") is True
        assert "Title for deletion test" in data.get("title", "")

    def test_item_no_longer_in_list(self, api):
        """Deleted item should not appear in subsequent queries."""
        api.create_todo("Vanishing todo 12345")

        todos = api.get_all_todos().json()["todos"]
        todo = next((t for t in todos if "Vanishing todo 12345" in t.get("title", "")), None)
        assert todo is not None

        # Delete it
        api.post("/delete", json={
            "file": todo["file"],
            "position": todo["pos"]
        })

        # Verify it's gone
        todos_after = api.get_all_todos().json()["todos"]
        found = next((t for t in todos_after if "Vanishing todo 12345" in t.get("title", "")), None)
        assert found is None, "Todo should have been deleted"
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_delete.py::TestDeleteTodo::test_returns_200_on_success -v`
Expected: FAIL with 404 (endpoint doesn't exist yet)

**Step 3: Commit test file**

```bash
git add tests/test_delete.py
git commit -m "test: add basic delete endpoint tests"
```

---

## Task 2: Implement Basic Delete Servlet

**Files:**
- Modify: `org-agenda-api.el` (add after the /complete servlet, around line 1080)

**Step 1: Add the delete servlet**

Add this code after the existing `/complete` servlet definition:

```elisp
(defservlet delete application/json (_path _query headers)
  "Endpoint: Delete an org item permanently.
Accepts JSON body with either:
  - id: org-id to locate the item
  - file + position: direct file location
Optional:
  - include_children: if true, delete subtree even if item has children"
  (condition-case err
      (let* ((content-header (cadr (assoc "Content" headers)))
             (json-data (json-parse-string content-header))
             (id (gethash "id" json-data))
             (file (gethash "file" json-data))
             (position (gethash "position" json-data))
             (include-children (eq (gethash "include_children" json-data) t))
             (result (org-agenda-api--delete-item id file position include-children)))
        (insert (json-encode result)))
    (error
     (org-agenda-api--log-error-with-backtrace "/delete" err)
     (insert (json-encode `(("status" . "error")
                            ("message" . ,(error-message-string err)))))))
  (org-agenda-api--track-request))
```

**Step 2: Add the delete-item function**

Add this helper function before the servlet:

```elisp
(defun org-agenda-api--delete-item (id file position include-children)
  "Delete an org item identified by ID or FILE+POSITION.
If INCLUDE-CHILDREN is nil and item has children, return error.
Returns alist with deletion result."
  ;; Locate the item
  (let* ((location (cond
                    (id (org-id-find id))
                    ((and file position) (cons file position))
                    (t (error "Must provide either 'id' or 'file' and 'position'"))))
         (target-file (car location))
         (target-pos (cdr location)))

    (unless location
      (error "Item not found"))

    (unless (file-exists-p target-file)
      (error "File not found: %s" target-file))

    ;; Verify file is in agenda files (security check)
    (unless (member target-file (org-agenda-files))
      (error "File is not an agenda file: %s" target-file))

    ;; Open file and navigate to position
    (with-current-buffer (find-file-noselect target-file)
      (widen)
      (goto-char target-pos)

      ;; Verify we're at a heading
      (unless (org-at-heading-p)
        (error "Position is not at a headline"))

      ;; Get title before deletion
      (let ((title (org-get-heading t t t t))
            (children-count 0))

        ;; Count direct children
        (save-excursion
          (when (org-goto-first-child)
            (setq children-count 1)
            (while (org-get-next-sibling)
              (setq children-count (1+ children-count)))))

        ;; Check if we need confirmation for children
        (when (and (> children-count 0) (not include-children))
          (error "Item has %d children. Set include_children=true to delete subtree."
                 children-count))

        ;; Delete the subtree
        (org-cut-subtree)
        (save-buffer)

        ;; Invalidate cache
        (org-agenda-api--invalidate-cache)

        ;; Return result
        (if (> children-count 0)
            `(("deleted" . t)
              ("title" . ,title)
              ("children_deleted" . ,children-count))
          `(("deleted" . t)
            ("title" . ,title)))))))
```

**Step 3: Run test to verify it passes**

Run: `pytest tests/test_delete.py::TestDeleteTodo::test_returns_200_on_success -v`
Expected: PASS

**Step 4: Run all delete tests**

Run: `pytest tests/test_delete.py -v`
Expected: All 3 tests PASS

**Step 5: Commit implementation**

```bash
git add org-agenda-api.el
git commit -m "feat: add POST /delete endpoint for removing org items"
```

---

## Task 3: Add Delete by ID Test

**Files:**
- Modify: `tests/test_delete.py`

**Step 1: Add test for delete by org-id**

```python
    def test_delete_by_id(self, api):
        """Should be able to delete by org-id."""
        api.create_todo("Delete by ID test")

        todos = api.get_all_todos().json()["todos"]
        todo = next((t for t in todos if "Delete by ID test" in t.get("title", "")), None)
        assert todo is not None

        # Skip if no ID assigned
        if not todo.get("id"):
            pytest.skip("Todo has no org-id assigned")

        response = api.post("/delete", json={"id": todo["id"]})
        assert response.status_code == 200
        assert response.json().get("deleted") is True
```

**Step 2: Run test**

Run: `pytest tests/test_delete.py::TestDeleteTodo::test_delete_by_id -v`
Expected: PASS (or SKIP if no org-id)

**Step 3: Commit**

```bash
git add tests/test_delete.py
git commit -m "test: add delete by org-id test"
```

---

## Task 4: Add Error Handling Tests

**Files:**
- Modify: `tests/test_delete.py`

**Step 1: Add error handling tests**

```python
class TestDeleteErrors:
    """Tests for delete endpoint error handling."""

    def test_error_on_not_found(self, api):
        """Should return error for non-existent item."""
        response = api.post("/delete", json={
            "file": "/nonexistent/file.org",
            "position": 1
        })
        data = response.json()
        assert "error" in data or data.get("status") == "error"

    def test_error_on_missing_params(self, api):
        """Should return error if neither id nor file+position provided."""
        response = api.post("/delete", json={})
        data = response.json()
        assert "error" in data or data.get("status") == "error"
```

**Step 2: Run tests**

Run: `pytest tests/test_delete.py::TestDeleteErrors -v`
Expected: PASS

**Step 3: Commit**

```bash
git add tests/test_delete.py
git commit -m "test: add delete error handling tests"
```

---

## Task 5: Add Children Protection Tests

**Files:**
- Modify: `tests/test_delete.py`
- Modify: `tests/fixtures/sample.org` (or create test fixture with children)

**Step 1: Create fixture with parent/child structure**

Add to `tests/conftest.py` in `org_test_dir` fixture:

```python
    # Create file with parent/child structure for delete tests
    hierarchy_org = test_dir / "hierarchy.org"
    hierarchy_org.write_text("""\
#+TITLE: Hierarchy Test

* TODO Parent task
** TODO Child task 1
** TODO Child task 2
** TODO Child task 3

* TODO Standalone task
""")
```

**Step 2: Add children protection test**

```python
class TestDeleteWithChildren:
    """Tests for delete behavior with child items."""

    def test_refuses_delete_with_children(self, api):
        """Should refuse to delete item with children unless confirmed."""
        todos = api.get_all_todos().json()["todos"]
        parent = next((t for t in todos if "Parent task" in t.get("title", "")), None)

        if parent is None:
            pytest.skip("Parent task fixture not found")

        response = api.post("/delete", json={
            "file": parent["file"],
            "position": parent["pos"]
        })
        data = response.json()

        # Should return error about children
        assert data.get("status") == "error" or "children" in data.get("message", "").lower() or "children" in data.get("error", "").lower()

    def test_deletes_with_children_when_confirmed(self, api):
        """Should delete subtree when include_children=true."""
        todos = api.get_all_todos().json()["todos"]
        parent = next((t for t in todos if "Parent task" in t.get("title", "")), None)

        if parent is None:
            pytest.skip("Parent task fixture not found")

        response = api.post("/delete", json={
            "file": parent["file"],
            "position": parent["pos"],
            "include_children": True
        })
        data = response.json()

        assert data.get("deleted") is True
        assert data.get("children_deleted", 0) > 0
```

**Step 3: Run tests**

Run: `pytest tests/test_delete.py::TestDeleteWithChildren -v`
Expected: PASS

**Step 4: Commit**

```bash
git add tests/test_delete.py tests/conftest.py
git commit -m "test: add delete with children protection tests"
```

---

## Task 6: Add delete Method to APIClient

**Files:**
- Modify: `tests/conftest.py`

**Step 1: Add delete helper method**

Add to APIClient class:

```python
    def delete_todo(self, todo: dict, include_children: bool = False) -> requests.Response:
        """POST /delete"""
        payload = {
            "file": todo.get("file"),
            "position": todo.get("pos"),
        }
        if todo.get("id"):
            payload["id"] = todo["id"]
        if include_children:
            payload["include_children"] = True
        return self.post("/delete", json=payload)
```

**Step 2: Run all tests to verify nothing broke**

Run: `pytest tests/ -v --tb=short`
Expected: All tests PASS

**Step 3: Commit**

```bash
git add tests/conftest.py
git commit -m "feat: add delete_todo helper to test APIClient"
```

---

## Task 7: Final Verification

**Step 1: Run full test suite**

Run: `pytest tests/ -v`
Expected: All tests PASS

**Step 2: Create final commit if needed**

```bash
git log --oneline -5
```

**Step 3: Summary of changes**

- Added `POST /delete` endpoint
- Supports deletion by org-id or file+position
- Children protection (requires `include_children: true`)
- Proper error handling
- Cache invalidation after delete
- Full test coverage
