# Metadata Endpoint Consolidation

## Problem

1. Multiple separate API calls needed on app startup (`/capture-templates`, `/filter-options`, `/todo-states`, `/custom-views`)
2. Error `wrong-type-argument listp [DONE HANDLED EXPIRED CANCELED]` in `filter-options` - the todo-states parsing doesn't handle vectors in `org-todo-keywords`
3. No shared logic between endpoints that return similar/overlapping data

## Solution

Create a consolidated `/metadata` endpoint that returns all configuration data in a single request, while keeping individual endpoints functional (backwards compatibility).

## Response Structure

```json
{
  "templates": { ... },
  "filterOptions": { ... },
  "todoStates": { ... },
  "customViews": { ... },
  "errors": ["section: error message", ...]
}
```

- Each section matches the existing individual endpoint response exactly
- Sections that fail return `null` with error logged in `errors` array
- Frontend can use partial data and handle failures gracefully

## Implementation Plan

### Phase 1: Backend (org-agenda-api.el)

1. **Fix vector/list bug** in `org-agenda-api--get-todo-states`
   - Handle both lists and vectors in `org-todo-keywords` using `seq-into` or type checking

2. **Extract shared data functions** (ensure these return alists, not JSON):
   - `org-agenda-api--get-todo-states-data`
   - `org-agenda-api--get-filter-options-data`
   - `org-agenda-api--get-templates-data`
   - `org-agenda-api--get-custom-views-data`

3. **Add `/metadata` endpoint**:
   - Call each helper in `condition-case`
   - Collect successful results and errors
   - Return combined response

4. **Refactor existing endpoints** to be thin wrappers around shared helpers

### Phase 2: Frontend (mova/)

1. **API Service** (`services/api.ts`):
   - Add `MetadataResponse` type
   - Add `getMetadata()` method

2. **Context** (`context/TemplatesContext.tsx`):
   - Replace separate API calls with single `getMetadata()`
   - Store and expose: `templates`, `filterOptions`, `todoStates`, `customViews`
   - Log any errors from `errors` array

3. **Components**:
   - `StatePicker.tsx` - Consume `todoStates` from context instead of own API call
   - Other components already use context, minimal changes needed

### Phase 3: Testing

- Add integration tests for `/metadata` endpoint
- Verify individual endpoints still work
- Test error scenarios (malformed config)

## Version

Bump to 0.6.0 (new feature, no breaking changes)
