# Filter/Narrowing for Agenda Views and Search

## Overview

Add filtering/narrowing functionality to Agenda, Custom Views, and Search screens using pill-style chips with modal selection. Filters are global (shared across all screens) and persisted.

## Filter Types

| Type | Selection Mode | Display |
|------|----------------|---------|
| TODO State | Multi-select (OR) | "State: TODO, NEXT" |
| Priority | Threshold (at least) | "Priority: B+" |
| Tags | Multi-select (OR) | "Tags: work, urgent" |
| Category | Multi-select (OR) | "Category: Work, Personal" |

Filtering logic: AND between filter types, OR within each type (except Priority which uses threshold).

## Data Model

### Filter State

```typescript
interface ActiveFilters {
  todoStates: Set<string>;        // empty = no filter
  priorityThreshold: string | null; // "A", "B", etc. - shows this level and higher
  tags: Set<string>;
  categories: Set<string>;
}
```

### API Response Types

```typescript
// GET /filter-options
interface FilterOptionsResponse {
  todoStates: string[];   // ["TODO", "NEXT", "WAITING", "DONE", ...]
  priorities: string[];   // ["A", "B", "C", "D", "E"]
  tags: string[];         // ["work", "home", "urgent", ...]
  categories: string[];   // ["Personal", "Work", "Projects", ...]
}

// Updated Todo interface
interface Todo {
  // ... existing fields
  category: string | null;  // NEW: CATEGORY property value (with inheritance)
}
```

## API Changes (org-agenda-api.el)

### 1. Add category to entry serialization

Update existing entry/todo JSON serialization to include the CATEGORY property:

```elisp
;; Use org-get-category or (org-entry-get nil "CATEGORY" t) for inheritance
```

### 2. New endpoint: `/filter-options`

```elisp
(defservlet filter-options application/json ()
  "Return all available filter options from agenda files.")
```

Implementation sources:
- `todoStates`: `org-todo-keywords-1` or configured keywords
- `priorities`: Range from `org-priority-highest` to `org-priority-lowest`
- `tags`: `org-get-buffer-tags` or `org-global-tags-completion-table`
- `categories`: Scan files for `#+CATEGORY:` keywords and `:CATEGORY:` properties

## UI Components

### FilterBar

Horizontal `ScrollView` below screen header containing:
- "+" chip (always visible) - opens filter type menu
- Active filter chips showing type + values + X button
- "Clear All" chip (appears when 2+ filters active)

```
[+ Add Filter] [State: TODO, NEXT ×] [Priority: B+ ×] [Clear All]
```

### FilterTypeMenu

`Menu` component (react-native-paper) opened by "+" chip:
- State (disabled if already added)
- Priority (disabled if already added)
- Tags (disabled if already added)
- Category (disabled if already added)

### FilterModal

Reusable modal for selecting filter values:
- **State/Tags/Category**: Chip-based multi-select grid
- **Priority**: Radio-button single-select showing "A (highest)" through "E (lowest)" with threshold semantics

## State Management

### FilterContext

```typescript
// context/FilterContext.tsx
interface FilterContextType {
  filters: ActiveFilters;
  setFilter: (type: FilterType, values: Set<string> | string | null) => void;
  clearFilter: (type: FilterType) => void;
  clearAllFilters: () => void;
  filterOptions: FilterOptionsResponse | null;
  isLoading: boolean;
  hasActiveFilters: boolean;
}
```

### Persistence

- Filters: AsyncStorage key `@mova_active_filters`
- Filter options: Cached in `@mova_filter_options`, refreshed on app start

### Provider Placement

```tsx
// app/_layout.tsx
<AuthProvider>
  <ColorPaletteProvider>
    <FilterProvider>
      {children}
    </FilterProvider>
  </ColorPaletteProvider>
</AuthProvider>
```

## Screen Integration

### Shared Hook

```typescript
// hooks/useFilteredTodos.ts
function useFilteredTodos(todos: Todo[]): Todo[] {
  const { filters } = useFilterContext();

  return useMemo(() => {
    return todos.filter(todo => {
      if (filters.todoStates.size > 0 && !filters.todoStates.has(todo.todo))
        return false;
      if (filters.priorityThreshold && !meetsThreshold(todo.priority, filters.priorityThreshold))
        return false;
      if (filters.tags.size > 0 && !todo.tags?.some(t => filters.tags.has(t)))
        return false;
      if (filters.categories.size > 0 && !filters.categories.has(todo.category))
        return false;
      return true;
    });
  }, [todos, filters]);
}

function meetsThreshold(priority: string | null, threshold: string): boolean {
  if (!priority) return false;
  return priority.charCodeAt(0) <= threshold.charCodeAt(0);
}
```

### Per-Screen Changes

1. **Agenda (`app/(tabs)/index.tsx`)**:
   - Add `<FilterBar />` below date navigation
   - Wrap entries with `useFilteredTodos()`

2. **Custom Views (`app/(tabs)/views.tsx`)**:
   - Add `<FilterBar />` below view title (when viewing entries)
   - Apply `useFilteredTodos()` to view entries

3. **Search (`app/(tabs)/search.tsx`)**:
   - Add `<FilterBar />` below search input
   - Apply `useFilteredTodos()` after text filtering (filters stack)

### Empty State

When filters result in zero items:
- Message: "No items match current filters"
- "Clear Filters" button

## File Structure

### New Files

```
mova/
├── context/
│   └── FilterContext.tsx       # Filter state, persistence, API fetch
├── components/
│   ├── FilterBar.tsx           # Horizontal scrollable filter chips
│   ├── FilterTypeMenu.tsx      # Menu for adding new filter
│   └── FilterModal.tsx         # Modal for selecting filter values
├── hooks/
│   └── useFilteredTodos.ts     # Apply filters to todo arrays
└── types/
    └── filters.ts              # Filter-related type definitions
```

### Modified Files

```
mova/
├── app/_layout.tsx             # Add FilterProvider
├── app/(tabs)/index.tsx        # Add FilterBar + useFilteredTodos
├── app/(tabs)/views.tsx        # Add FilterBar + useFilteredTodos
├── app/(tabs)/search.tsx       # Add FilterBar + useFilteredTodos
└── services/api.ts             # Add getFilterOptions() method

org-agenda-api.el               # Add category field + /filter-options endpoint
```

## Summary of Decisions

| Aspect | Decision |
|--------|----------|
| Screens | All three: Agenda, Custom Views, Search |
| Filter types | TODO state, Priority (threshold), Tags, Category |
| UI location | Horizontal filter bar below header |
| Selection | Multi-select for all except Priority (threshold) |
| Chip display | One chip per filter type with values |
| Adding filters | "+" chip opens menu |
| Persistence | Global across screens, AsyncStorage |
| Clearing | X per chip, Clear All when 2+ active |
| Options source | Dedicated `/filter-options` API endpoint |
| Category source | CATEGORY property with inheritance |
