# Metadata Consolidation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Consolidate `/capture-templates`, `/filter-options`, `/todo-states`, and `/custom-views` into a single `/metadata` endpoint with shared backend logic.

**Architecture:** Fix vector/list bug in todo-states parsing, extract shared data helpers, create `/metadata` endpoint that calls each helper with error handling, update frontend to use single request.

**Tech Stack:** Emacs Lisp (backend), TypeScript/React (frontend), Jest (tests)

---

### Task 1: Fix vector/list bug in todo-states parsing

**Files:**
- Modify: `org-agenda-api.el:1080-1100`

**Step 1: Update `org-agenda-api--get-todo-states` to handle vectors**

Replace the function at line 1080:

```elisp
(defun org-agenda-api--get-todo-states ()
  "Get all configured TODO states from `org-todo-keywords'.
Returns an alist with 'active' (not-done) and 'done' states.
Handles both list and vector formats in org-todo-keywords."
  (let ((active-states nil)
        (done-states nil))
    (dolist (keyword-set org-todo-keywords)
      (let ((in-done-section nil)
            ;; Convert to list if it's a vector, skip first element (sequence/type)
            (keywords (cdr (if (vectorp keyword-set)
                               (append keyword-set nil)
                             keyword-set))))
        (dolist (keyword keywords)
          (cond
           ((string= keyword "|")
            (setq in-done-section t))
           (t
            ;; Handle keywords with shortcuts like "TODO(t)"
            (let ((clean-keyword (if (string-match-p "(.*)$" keyword)
                                     (replace-regexp-in-string "(.*)$" "" keyword)
                                   keyword)))
              (if in-done-section
                  (push clean-keyword done-states)
                (push clean-keyword active-states))))))))
    `(("active" . ,(vconcat (nreverse active-states)))
      ("done" . ,(vconcat (nreverse done-states))))))
```

**Step 2: Test manually via Emacs**

Run in Emacs:
```elisp
(setq org-todo-keywords '((sequence "TODO" "NEXT" "|" "DONE")))
(org-agenda-api--get-todo-states)
;; Expected: (("active" . ["TODO" "NEXT"]) ("done" . ["DONE"]))

;; Test vector format
(setq org-todo-keywords '[["sequence" "TODO" "NEXT" "|" "DONE"]])
(org-agenda-api--get-todo-states)
;; Expected: same result
```

**Step 3: Commit**

```bash
git add org-agenda-api.el
git commit -m "fix: handle vectors in org-todo-keywords parsing"
```

---

### Task 2: Add `/metadata` endpoint to backend

**Files:**
- Modify: `org-agenda-api.el` (add after line ~1184, after custom-views endpoint)

**Step 1: Add the metadata endpoint**

Add after the `custom-views` endpoint (around line 1184):

```elisp
(defservlet metadata application/json ()
  "Endpoint: Return all app metadata in a single request.
Returns templates, filterOptions, todoStates, customViews, and any errors."
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
    ;; Add errors array
    (push `("errors" . ,(vconcat (nreverse errors))) result)
    (insert (json-encode (nreverse result))))
  (org-agenda-api--track-request))
```

**Step 2: Commit**

```bash
git add org-agenda-api.el
git commit -m "feat: add /metadata endpoint for consolidated config"
```

---

### Task 3: Add MetadataResponse type and getMetadata() to frontend API

**Files:**
- Modify: `mova/services/api.ts`

**Step 1: Add MetadataResponse interface**

Add after `FilterOptionsResponse` interface (around line 121):

```typescript
export interface MetadataResponse {
  templates: TemplatesResponse | null;
  filterOptions: FilterOptionsResponse | null;
  todoStates: TodoStatesResponse | null;
  customViews: CustomViewsResponse | null;
  errors: string[];
}
```

**Step 2: Add getMetadata() method**

Add after `getFilterOptions()` method (around line 286):

```typescript
async getMetadata(): Promise<MetadataResponse> {
  return this.request<MetadataResponse>("/metadata");
}
```

**Step 3: Commit**

```bash
git add mova/services/api.ts
git commit -m "feat: add getMetadata() API method"
```

---

### Task 4: Update TemplatesContext to use getMetadata()

**Files:**
- Modify: `mova/context/TemplatesContext.tsx`

**Step 1: Update imports**

Change line 2:

```typescript
import { api, CustomViewsResponse, FilterOptionsResponse, MetadataResponse, TemplatesResponse, TodoStatesResponse } from "@/services/api";
```

**Step 2: Add todoStates and customViews to context type**

Replace interface at lines 12-18:

```typescript
interface TemplatesContextType {
  templates: TemplatesResponse | null;
  filterOptions: FilterOptionsResponse | null;
  todoStates: TodoStatesResponse | null;
  customViews: CustomViewsResponse | null;
  isLoading: boolean;
  error: string | null;
  reloadTemplates: () => Promise<void>;
}
```

**Step 3: Add state for todoStates and customViews**

Add after line 27 (after filterOptions state):

```typescript
const [todoStates, setTodoStates] = useState<TodoStatesResponse | null>(null);
const [customViews, setCustomViews] = useState<CustomViewsResponse | null>(null);
```

**Step 4: Replace reloadTemplates implementation**

Replace the `reloadTemplates` callback (lines 32-66):

```typescript
const reloadTemplates = useCallback(async () => {
  if (!apiUrl || !username || !password) {
    return;
  }

  setIsLoading(true);
  setError(null);

  api.configure(apiUrl, username, password);

  try {
    const metadata = await api.getMetadata();

    // Log any errors from the backend
    if (metadata.errors && metadata.errors.length > 0) {
      console.warn("Metadata fetch had errors:", metadata.errors);
    }

    setTemplates(metadata.templates);
    setFilterOptions(metadata.filterOptions);
    setTodoStates(metadata.todoStates);
    setCustomViews(metadata.customViews);

    // Set error if templates failed (critical)
    if (!metadata.templates) {
      setError("Failed to load templates");
    }
  } catch (err) {
    console.error("Failed to load metadata:", err);
    setError(err instanceof Error ? err.message : "Failed to load metadata");
  }

  setIsLoading(false);
}, [apiUrl, username, password]);
```

**Step 5: Update useEffect to clear all state on logout**

Replace lines 68-76:

```typescript
useEffect(() => {
  if (isAuthenticated) {
    reloadTemplates();
  } else {
    // Clear all state when logged out
    setTemplates(null);
    setFilterOptions(null);
    setTodoStates(null);
    setCustomViews(null);
  }
}, [isAuthenticated, reloadTemplates]);
```

**Step 6: Update Provider value**

Replace line 80:

```typescript
value={{ templates, filterOptions, todoStates, customViews, isLoading, error, reloadTemplates }}
```

**Step 7: Commit**

```bash
git add mova/context/TemplatesContext.tsx
git commit -m "feat: use getMetadata() in TemplatesContext"
```

---

### Task 5: Update StatePicker to use context

**Files:**
- Modify: `mova/components/capture/StatePicker.tsx`

**Step 1: Replace entire file**

```typescript
// components/capture/StatePicker.tsx
import { useTemplates } from "@/context/TemplatesContext";
import React from "react";
import { StyleSheet, View } from "react-native";
import { Chip, Text } from "react-native-paper";

interface StatePickerProps {
  value: string;
  onChange: (value: string) => void;
}

export function StatePicker({ value, onChange }: StatePickerProps) {
  const { todoStates } = useTemplates();

  const allStates = todoStates
    ? [...todoStates.active, ...todoStates.done]
    : ["TODO", "NEXT", "WAITING", "DONE"];

  return (
    <View style={styles.container}>
      <Text variant="bodySmall" style={styles.label}>
        State
      </Text>
      <View style={styles.chips}>
        {allStates.map((state) => (
          <Chip
            key={state}
            selected={value === state}
            onPress={() => onChange(state)}
            style={styles.chip}
            compact
          >
            {state}
          </Chip>
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    marginBottom: 16,
  },
  label: {
    marginBottom: 8,
    opacity: 0.7,
  },
  chips: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
  },
  chip: {},
});
```

**Step 2: Commit**

```bash
git add mova/components/capture/StatePicker.tsx
git commit -m "refactor: StatePicker uses todoStates from context"
```

---

### Task 6: Add getMetadata() to TestApiClient

**Files:**
- Modify: `mova/tests/utils/container.ts`

**Step 1: Add getMetadata method**

Add after `updateTodo` method (around line 325):

```typescript
async getMetadata() {
  return this.get<{
    templates: any;
    filterOptions: any;
    todoStates: any;
    customViews: any;
    errors: string[];
  }>("/metadata");
}
```

**Step 2: Commit**

```bash
git add mova/tests/utils/container.ts
git commit -m "test: add getMetadata() to TestApiClient"
```

---

### Task 7: Add integration tests for /metadata endpoint

**Files:**
- Modify: `mova/tests/integration/api.test.ts`

**Step 1: Add test describe block**

Add after the `GET /custom-view` describe block (around line 506):

```typescript
describe("GET /metadata", () => {
  it("should return all metadata in one request", async () => {
    const response = await client.getMetadata();

    expect(response).toHaveProperty("templates");
    expect(response).toHaveProperty("filterOptions");
    expect(response).toHaveProperty("todoStates");
    expect(response).toHaveProperty("customViews");
    expect(response).toHaveProperty("errors");
    expect(Array.isArray(response.errors)).toBe(true);
  });

  it("should return templates matching /capture-templates", async () => {
    const metadata = await client.getMetadata();

    expect(metadata.templates).toBeTruthy();
    expect(metadata.templates).toHaveProperty("default");
  });

  it("should return todoStates matching /todo-states", async () => {
    const metadata = await client.getMetadata();

    expect(metadata.todoStates).toBeTruthy();
    expect(metadata.todoStates).toHaveProperty("active");
    expect(metadata.todoStates).toHaveProperty("done");
    expect(metadata.todoStates.active).toContain("TODO");
    expect(metadata.todoStates.active).toContain("NEXT");
    expect(metadata.todoStates.done).toContain("DONE");
  });

  it("should return filterOptions matching /filter-options", async () => {
    const metadata = await client.getMetadata();

    expect(metadata.filterOptions).toBeTruthy();
    expect(metadata.filterOptions).toHaveProperty("todoStates");
    expect(metadata.filterOptions).toHaveProperty("priorities");
    expect(metadata.filterOptions).toHaveProperty("tags");
    expect(metadata.filterOptions).toHaveProperty("categories");
  });

  it("should return customViews matching /custom-views", async () => {
    const metadata = await client.getMetadata();

    expect(metadata.customViews).toBeTruthy();
    expect(metadata.customViews).toHaveProperty("views");
    expect(Array.isArray(metadata.customViews.views)).toBe(true);
    expect(metadata.customViews.views.length).toBeGreaterThan(0);
  });

  it("should have empty errors array on success", async () => {
    const metadata = await client.getMetadata();

    expect(metadata.errors).toEqual([]);
  });
});
```

**Step 2: Commit**

```bash
git add mova/tests/integration/api.test.ts
git commit -m "test: add integration tests for /metadata endpoint"
```

---

### Task 8: Run integration tests

**Step 1: Run the tests**

```bash
cd mova && npm test -- --testPathPattern=integration
```

Expected: All tests pass, including new `/metadata` tests.

**Step 2: If tests fail, debug and fix**

Check container logs if needed:
```bash
docker logs <container-name>
```

---

### Task 9: Bump version to 0.6.0

**Files:**
- Modify: `org-agenda-api.el` (version constant)
- Modify: `mova/package.json`

**Step 1: Find and update version in org-agenda-api.el**

Search for version definition and update to "0.6.0".

**Step 2: Update mova/package.json version**

Update `"version"` field to `"0.6.0"`.

**Step 3: Commit**

```bash
git add org-agenda-api.el mova/package.json
git commit -m "chore: bump version to 0.6.0"
```

---

### Task 10: Final commit - update mova submodule

**Step 1: Stage and commit all changes if any unstaged**

```bash
git status
git add -A
git commit -m "feat: consolidate metadata endpoints

- Fix vector/list bug in org-todo-keywords parsing
- Add /metadata endpoint returning all config in one request
- Update frontend to use single getMetadata() call
- StatePicker now uses todoStates from context
- Add integration tests for /metadata

Closes: metadata consolidation design"
```

**Step 2: Update mova submodule reference**

```bash
cd mova && git add -A && git commit -m "feat: use consolidated /metadata endpoint" && cd ..
git add mova
git commit -m "chore: update mova submodule"
```
