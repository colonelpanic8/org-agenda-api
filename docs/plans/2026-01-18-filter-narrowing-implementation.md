# Filter/Narrowing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add filtering/narrowing to Agenda, Custom Views, and Search screens using pill-style chips with modal selection.

**Architecture:** Global FilterContext manages filter state persisted in AsyncStorage. A `/filter-options` backend endpoint provides available options. Each screen applies filters via a shared `useFilteredTodos` hook. UI uses a horizontal FilterBar with add/remove chips.

**Tech Stack:** React Native, Expo, React Native Paper (Chip, Menu, Modal), TypeScript, AsyncStorage, Emacs Lisp (org-agenda-api.el)

**Worktree:** `/home/imalison/dotfiles/dotfiles/emacs.d/straight/repos/org-agenda-api/.worktrees/filter-narrowing`

---

## Task 1: Add Category to Backend Entry Serialization

**Files:**
- Modify: `org-agenda-api.el:471-483` (org-agenda-api--extract-entry-data function)
- Test: Manual test via curl

**Step 1: Add category extraction to entry data**

In `org-agenda-api--extract-entry-data`, add category extraction using `org-get-category`:

```elisp
;; Inside the let* block, after (notify-before ...) binding, add:
(category (org-get-category))
```

Then add it to the returned alist after `"notifyBefore"`:

```elisp
("category" . ,category)
```

**Step 2: Verify with curl**

Run the container or start the API, then:

```bash
curl -u user:pass http://localhost:8080/get-all-todos | jq '.todos[0]'
```

Expected: Response includes `"category": "SomeCategory"` field.

**Step 3: Commit**

```bash
git add org-agenda-api.el
git commit -m "feat(api): add category field to todo entries"
```

---

## Task 2: Add /filter-options Backend Endpoint

**Files:**
- Modify: `org-agenda-api.el` (add new endpoint after todo-states around line 1063)

**Step 1: Add helper function to collect filter options**

Add after `org-agenda-api--get-todo-states` function:

```elisp
(defun org-agenda-api--get-filter-options ()
  "Get all available filter options from agenda files.
Returns an alist with todoStates, priorities, tags, and categories."
  (let ((todo-states (org-agenda-api--get-todo-states))
        (priorities '())
        (tags '())
        (categories '()))
    ;; Get priority range
    (let ((highest (or org-priority-highest ?A))
          (lowest (or org-priority-lowest ?C)))
      (setq priorities
            (mapcar #'char-to-string
                    (number-sequence highest lowest))))
    ;; Collect tags and categories from all agenda files
    (dolist (file org-agenda-files)
      (when (file-readable-p file)
        (with-current-buffer (find-file-noselect file)
          ;; Get file-level category
          (save-excursion
            (goto-char (point-min))
            (when (re-search-forward "^#\\+CATEGORY:[ \t]+\\(.+\\)$" nil t)
              (let ((cat (string-trim (match-string 1))))
                (unless (member cat categories)
                  (push cat categories)))))
          ;; Get tags from buffer
          (let ((buffer-tags (org-get-buffer-tags)))
            (dolist (tag-pair buffer-tags)
              (let ((tag (car tag-pair)))
                (unless (member tag tags)
                  (push tag tags)))))
          ;; Get categories from headings
          (org-map-entries
           (lambda ()
             (let ((cat (org-get-category)))
               (when (and cat (not (member cat categories)))
                 (push cat categories))))
           nil 'file))))
    `(("todoStates" . ,(vconcat (append (cdr (assoc "active" todo-states))
                                        (cdr (assoc "done" todo-states)))))
      ("priorities" . ,(vconcat priorities))
      ("tags" . ,(vconcat (sort tags #'string<)))
      ("categories" . ,(vconcat (sort categories #'string<))))))
```

**Step 2: Add the endpoint**

Add after the `todo-states` defservlet:

```elisp
(defservlet filter-options application/json ()
  "Endpoint: Return all available filter options for the UI.
Returns todoStates, priorities, tags, and categories."
  (insert (json-encode (org-agenda-api--get-filter-options)))
  (org-agenda-api--track-request))
```

**Step 3: Verify with curl**

```bash
curl -u user:pass http://localhost:8080/filter-options | jq
```

Expected: JSON with todoStates, priorities, tags, categories arrays.

**Step 4: Commit**

```bash
git add org-agenda-api.el
git commit -m "feat(api): add /filter-options endpoint"
```

---

## Task 3: Add TypeScript Types for Filters

**Files:**
- Create: `mova/types/filters.ts`

**Step 1: Create the types file**

```typescript
// Filter-related type definitions

export type FilterType = 'todoStates' | 'priority' | 'tags' | 'categories';

export interface ActiveFilters {
  todoStates: Set<string>;
  priorityThreshold: string | null;  // "A", "B", etc. - shows this level and higher
  tags: Set<string>;
  categories: Set<string>;
}

export interface FilterOptionsResponse {
  todoStates: string[];
  priorities: string[];
  tags: string[];
  categories: string[];
}

export const DEFAULT_FILTERS: ActiveFilters = {
  todoStates: new Set(),
  priorityThreshold: null,
  tags: new Set(),
  categories: new Set(),
};

// Serializable version for AsyncStorage
export interface SerializedFilters {
  todoStates: string[];
  priorityThreshold: string | null;
  tags: string[];
  categories: string[];
}

export function serializeFilters(filters: ActiveFilters): SerializedFilters {
  return {
    todoStates: Array.from(filters.todoStates),
    priorityThreshold: filters.priorityThreshold,
    tags: Array.from(filters.tags),
    categories: Array.from(filters.categories),
  };
}

export function deserializeFilters(serialized: SerializedFilters): ActiveFilters {
  return {
    todoStates: new Set(serialized.todoStates),
    priorityThreshold: serialized.priorityThreshold,
    tags: new Set(serialized.tags),
    categories: new Set(serialized.categories),
  };
}

export function hasActiveFilters(filters: ActiveFilters): boolean {
  return (
    filters.todoStates.size > 0 ||
    filters.priorityThreshold !== null ||
    filters.tags.size > 0 ||
    filters.categories.size > 0
  );
}

export function countActiveFilters(filters: ActiveFilters): number {
  let count = 0;
  if (filters.todoStates.size > 0) count++;
  if (filters.priorityThreshold !== null) count++;
  if (filters.tags.size > 0) count++;
  if (filters.categories.size > 0) count++;
  return count;
}
```

**Step 2: Commit**

```bash
git add mova/types/filters.ts
git commit -m "feat: add TypeScript types for filters"
```

---

## Task 4: Update API Service with getFilterOptions

**Files:**
- Modify: `mova/services/api.ts`

**Step 1: Add FilterOptionsResponse import and method**

Add to the interfaces section (after line 97):

```typescript
export interface FilterOptionsResponse {
  todoStates: string[];
  priorities: string[];
  tags: string[];
  categories: string[];
}
```

Add category to the Todo interface (after `notifyBefore`):

```typescript
category: string | null;
```

Add method to OrgAgendaApi class (after getVersion):

```typescript
async getFilterOptions(): Promise<FilterOptionsResponse> {
  return this.request<FilterOptionsResponse>("/filter-options");
}
```

**Step 2: Run type check**

```bash
cd mova && npx tsc --noEmit
```

Expected: No errors.

**Step 3: Commit**

```bash
git add mova/services/api.ts
git commit -m "feat(api): add getFilterOptions method and category to Todo"
```

---

## Task 5: Create FilterContext

**Files:**
- Create: `mova/context/FilterContext.tsx`

**Step 1: Create the context file**

```typescript
/**
 * Filter Context
 *
 * Provides global filter state for narrowing agenda views.
 * Filters are persisted to AsyncStorage and shared across all screens.
 */

import { api, FilterOptionsResponse } from "@/services/api";
import {
  ActiveFilters,
  DEFAULT_FILTERS,
  deserializeFilters,
  FilterType,
  hasActiveFilters,
  serializeFilters,
} from "@/types/filters";
import AsyncStorage from "@react-native-async-storage/async-storage";
import React, {
  createContext,
  ReactNode,
  useCallback,
  useContext,
  useEffect,
  useState,
} from "react";

const FILTERS_STORAGE_KEY = "@mova_active_filters";
const OPTIONS_STORAGE_KEY = "@mova_filter_options";

interface FilterContextType {
  filters: ActiveFilters;
  filterOptions: FilterOptionsResponse | null;
  isLoading: boolean;
  hasActiveFilters: boolean;
  setTodoStates: (states: Set<string>) => void;
  setPriorityThreshold: (priority: string | null) => void;
  setTags: (tags: Set<string>) => void;
  setCategories: (categories: Set<string>) => void;
  clearFilter: (type: FilterType) => void;
  clearAllFilters: () => void;
  refreshFilterOptions: () => Promise<void>;
}

const FilterContext = createContext<FilterContextType | undefined>(undefined);

export function FilterProvider({ children }: { children: ReactNode }) {
  const [filters, setFilters] = useState<ActiveFilters>(DEFAULT_FILTERS);
  const [filterOptions, setFilterOptions] = useState<FilterOptionsResponse | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  // Load saved filters and options on mount
  useEffect(() => {
    loadState();
  }, []);

  // Save filters whenever they change
  useEffect(() => {
    if (!isLoading) {
      saveFilters(filters);
    }
  }, [filters, isLoading]);

  async function loadState() {
    try {
      const [storedFilters, storedOptions] = await Promise.all([
        AsyncStorage.getItem(FILTERS_STORAGE_KEY),
        AsyncStorage.getItem(OPTIONS_STORAGE_KEY),
      ]);

      if (storedFilters) {
        const parsed = JSON.parse(storedFilters);
        setFilters(deserializeFilters(parsed));
      }

      if (storedOptions) {
        setFilterOptions(JSON.parse(storedOptions));
      }
    } catch (error) {
      console.error("Failed to load filter state:", error);
    } finally {
      setIsLoading(false);
    }
  }

  async function saveFilters(newFilters: ActiveFilters) {
    try {
      await AsyncStorage.setItem(
        FILTERS_STORAGE_KEY,
        JSON.stringify(serializeFilters(newFilters))
      );
    } catch (error) {
      console.error("Failed to save filters:", error);
    }
  }

  const refreshFilterOptions = useCallback(async () => {
    try {
      const options = await api.getFilterOptions();
      setFilterOptions(options);
      await AsyncStorage.setItem(OPTIONS_STORAGE_KEY, JSON.stringify(options));
    } catch (error) {
      console.error("Failed to fetch filter options:", error);
    }
  }, []);

  const setTodoStates = useCallback((states: Set<string>) => {
    setFilters((prev) => ({ ...prev, todoStates: states }));
  }, []);

  const setPriorityThreshold = useCallback((priority: string | null) => {
    setFilters((prev) => ({ ...prev, priorityThreshold: priority }));
  }, []);

  const setTags = useCallback((tags: Set<string>) => {
    setFilters((prev) => ({ ...prev, tags: tags }));
  }, []);

  const setCategories = useCallback((categories: Set<string>) => {
    setFilters((prev) => ({ ...prev, categories: categories }));
  }, []);

  const clearFilter = useCallback((type: FilterType) => {
    setFilters((prev) => {
      switch (type) {
        case "todoStates":
          return { ...prev, todoStates: new Set() };
        case "priority":
          return { ...prev, priorityThreshold: null };
        case "tags":
          return { ...prev, tags: new Set() };
        case "categories":
          return { ...prev, categories: new Set() };
        default:
          return prev;
      }
    });
  }, []);

  const clearAllFilters = useCallback(() => {
    setFilters(DEFAULT_FILTERS);
  }, []);

  return (
    <FilterContext.Provider
      value={{
        filters,
        filterOptions,
        isLoading,
        hasActiveFilters: hasActiveFilters(filters),
        setTodoStates,
        setPriorityThreshold,
        setTags,
        setCategories,
        clearFilter,
        clearAllFilters,
        refreshFilterOptions,
      }}
    >
      {children}
    </FilterContext.Provider>
  );
}

export function useFilters() {
  const context = useContext(FilterContext);
  if (context === undefined) {
    throw new Error("useFilters must be used within a FilterProvider");
  }
  return context;
}
```

**Step 2: Run type check**

```bash
cd mova && npx tsc --noEmit
```

**Step 3: Commit**

```bash
git add mova/context/FilterContext.tsx
git commit -m "feat: add FilterContext for global filter state"
```

---

## Task 6: Add FilterProvider to App Layout

**Files:**
- Modify: `mova/app/_layout.tsx`

**Step 1: Import and wrap with FilterProvider**

Add import at top:

```typescript
import { FilterProvider } from "@/context/FilterContext";
```

Update the RootLayout return to add FilterProvider inside AuthProvider:

```tsx
<AuthProvider>
  <FilterProvider>
    <RootLayoutNav />
  </FilterProvider>
</AuthProvider>
```

**Step 2: Run type check**

```bash
cd mova && npx tsc --noEmit
```

**Step 3: Commit**

```bash
git add mova/app/_layout.tsx
git commit -m "feat: add FilterProvider to app layout"
```

---

## Task 7: Create useFilteredTodos Hook

**Files:**
- Create: `mova/hooks/useFilteredTodos.ts`

**Step 1: Create the hook**

```typescript
import { useFilters } from "@/context/FilterContext";
import { Todo } from "@/services/api";
import { useMemo } from "react";

/**
 * Check if a priority meets the threshold (at least as high).
 * Priority A is highest, so A <= threshold means it passes.
 */
function meetsThreshold(priority: string | null, threshold: string): boolean {
  if (!priority) return false;
  return priority.charCodeAt(0) <= threshold.charCodeAt(0);
}

/**
 * Hook to filter todos based on global filter state.
 * Returns filtered array - original array is not modified.
 */
export function useFilteredTodos<T extends Todo>(todos: T[]): T[] {
  const { filters } = useFilters();

  return useMemo(() => {
    return todos.filter((todo) => {
      // TODO state filter (multi-select, OR logic)
      if (filters.todoStates.size > 0 && !filters.todoStates.has(todo.todo)) {
        return false;
      }

      // Priority filter (threshold - at least this priority)
      if (
        filters.priorityThreshold &&
        !meetsThreshold(todo.priority, filters.priorityThreshold)
      ) {
        return false;
      }

      // Tags filter (multi-select, OR logic - todo must have at least one matching tag)
      if (
        filters.tags.size > 0 &&
        !todo.tags?.some((t) => filters.tags.has(t))
      ) {
        return false;
      }

      // Category filter (multi-select, OR logic)
      if (
        filters.categories.size > 0 &&
        (!todo.category || !filters.categories.has(todo.category))
      ) {
        return false;
      }

      return true;
    });
  }, [todos, filters]);
}
```

**Step 2: Run type check**

```bash
cd mova && npx tsc --noEmit
```

**Step 3: Commit**

```bash
git add mova/hooks/useFilteredTodos.ts
git commit -m "feat: add useFilteredTodos hook for applying filters"
```

---

## Task 8: Create FilterModal Component

**Files:**
- Create: `mova/components/FilterModal.tsx`

**Step 1: Create the modal component**

```typescript
import { FilterOptionsResponse } from "@/services/api";
import { FilterType } from "@/types/filters";
import React, { useEffect, useState } from "react";
import { ScrollView, StyleSheet, View } from "react-native";
import {
  Button,
  Chip,
  Modal,
  Portal,
  RadioButton,
  Text,
  useTheme,
} from "react-native-paper";

interface FilterModalProps {
  visible: boolean;
  onDismiss: () => void;
  filterType: FilterType;
  filterOptions: FilterOptionsResponse | null;
  // For multi-select (todoStates, tags, categories)
  selectedValues?: Set<string>;
  onSelectValues?: (values: Set<string>) => void;
  // For priority threshold
  selectedThreshold?: string | null;
  onSelectThreshold?: (threshold: string | null) => void;
}

export function FilterModal({
  visible,
  onDismiss,
  filterType,
  filterOptions,
  selectedValues,
  onSelectValues,
  selectedThreshold,
  onSelectThreshold,
}: FilterModalProps) {
  const theme = useTheme();
  const [localValues, setLocalValues] = useState<Set<string>>(new Set());
  const [localThreshold, setLocalThreshold] = useState<string | null>(null);

  // Sync local state when modal opens
  useEffect(() => {
    if (visible) {
      if (selectedValues) {
        setLocalValues(new Set(selectedValues));
      }
      if (selectedThreshold !== undefined) {
        setLocalThreshold(selectedThreshold);
      }
    }
  }, [visible, selectedValues, selectedThreshold]);

  const getOptions = (): string[] => {
    if (!filterOptions) return [];
    switch (filterType) {
      case "todoStates":
        return filterOptions.todoStates;
      case "tags":
        return filterOptions.tags;
      case "categories":
        return filterOptions.categories;
      case "priority":
        return filterOptions.priorities;
      default:
        return [];
    }
  };

  const getTitle = (): string => {
    switch (filterType) {
      case "todoStates":
        return "Filter by State";
      case "priority":
        return "Filter by Priority";
      case "tags":
        return "Filter by Tags";
      case "categories":
        return "Filter by Category";
      default:
        return "Filter";
    }
  };

  const toggleValue = (value: string) => {
    const newSet = new Set(localValues);
    if (newSet.has(value)) {
      newSet.delete(value);
    } else {
      newSet.add(value);
    }
    setLocalValues(newSet);
  };

  const handleApply = () => {
    if (filterType === "priority" && onSelectThreshold) {
      onSelectThreshold(localThreshold);
    } else if (onSelectValues) {
      onSelectValues(localValues);
    }
    onDismiss();
  };

  const handleClear = () => {
    if (filterType === "priority" && onSelectThreshold) {
      onSelectThreshold(null);
    } else if (onSelectValues) {
      onSelectValues(new Set());
    }
    onDismiss();
  };

  const options = getOptions();

  return (
    <Portal>
      <Modal
        visible={visible}
        onDismiss={onDismiss}
        contentContainerStyle={[
          styles.container,
          { backgroundColor: theme.colors.surface },
        ]}
      >
        <Text variant="titleLarge" style={styles.title}>
          {getTitle()}
        </Text>

        <ScrollView style={styles.optionsContainer}>
          {filterType === "priority" ? (
            <RadioButton.Group
              onValueChange={(value) =>
                setLocalThreshold(value === "" ? null : value)
              }
              value={localThreshold || ""}
            >
              <RadioButton.Item label="Any priority" value="" />
              {options.map((priority) => (
                <RadioButton.Item
                  key={priority}
                  label={`${priority} or higher`}
                  value={priority}
                />
              ))}
            </RadioButton.Group>
          ) : (
            <View style={styles.chipContainer}>
              {options.map((option) => (
                <Chip
                  key={option}
                  selected={localValues.has(option)}
                  onPress={() => toggleValue(option)}
                  style={styles.chip}
                  showSelectedCheck
                >
                  {option}
                </Chip>
              ))}
            </View>
          )}
        </ScrollView>

        <View style={styles.buttonRow}>
          <Button onPress={handleClear} textColor={theme.colors.error}>
            Clear
          </Button>
          <View style={styles.buttonSpacer} />
          <Button onPress={onDismiss}>Cancel</Button>
          <Button mode="contained" onPress={handleApply}>
            Apply
          </Button>
        </View>
      </Modal>
    </Portal>
  );
}

const styles = StyleSheet.create({
  container: {
    margin: 20,
    padding: 20,
    borderRadius: 12,
    maxHeight: "80%",
  },
  title: {
    marginBottom: 16,
  },
  optionsContainer: {
    maxHeight: 300,
  },
  chipContainer: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 8,
  },
  chip: {
    marginBottom: 4,
  },
  buttonRow: {
    flexDirection: "row",
    justifyContent: "flex-end",
    marginTop: 16,
    gap: 8,
  },
  buttonSpacer: {
    flex: 1,
  },
});
```

**Step 2: Run type check**

```bash
cd mova && npx tsc --noEmit
```

**Step 3: Commit**

```bash
git add mova/components/FilterModal.tsx
git commit -m "feat: add FilterModal component for selecting filter values"
```

---

## Task 9: Create FilterBar Component

**Files:**
- Create: `mova/components/FilterBar.tsx`

**Step 1: Create the component**

```typescript
import { useFilters } from "@/context/FilterContext";
import { countActiveFilters, FilterType } from "@/types/filters";
import React, { useEffect, useState } from "react";
import { ScrollView, StyleSheet, View } from "react-native";
import { Chip, Menu, useTheme } from "react-native-paper";
import { FilterModal } from "./FilterModal";

export function FilterBar() {
  const theme = useTheme();
  const {
    filters,
    filterOptions,
    hasActiveFilters,
    setTodoStates,
    setPriorityThreshold,
    setTags,
    setCategories,
    clearFilter,
    clearAllFilters,
    refreshFilterOptions,
  } = useFilters();

  const [menuVisible, setMenuVisible] = useState(false);
  const [modalType, setModalType] = useState<FilterType | null>(null);

  // Refresh filter options when component mounts
  useEffect(() => {
    refreshFilterOptions();
  }, [refreshFilterOptions]);

  const openModal = (type: FilterType) => {
    setMenuVisible(false);
    setModalType(type);
  };

  const formatFilterLabel = (type: FilterType): string => {
    switch (type) {
      case "todoStates":
        const states = Array.from(filters.todoStates);
        if (states.length === 0) return "";
        if (states.length <= 2) return `State: ${states.join(", ")}`;
        return `State: ${states.length} selected`;

      case "priority":
        return filters.priorityThreshold
          ? `Priority: ${filters.priorityThreshold}+`
          : "";

      case "tags":
        const tags = Array.from(filters.tags);
        if (tags.length === 0) return "";
        if (tags.length <= 2) return `Tags: ${tags.join(", ")}`;
        return `Tags: ${tags.length} selected`;

      case "categories":
        const cats = Array.from(filters.categories);
        if (cats.length === 0) return "";
        if (cats.length <= 2) return `Category: ${cats.join(", ")}`;
        return `Category: ${cats.length} selected`;

      default:
        return "";
    }
  };

  const isFilterActive = (type: FilterType): boolean => {
    switch (type) {
      case "todoStates":
        return filters.todoStates.size > 0;
      case "priority":
        return filters.priorityThreshold !== null;
      case "tags":
        return filters.tags.size > 0;
      case "categories":
        return filters.categories.size > 0;
      default:
        return false;
    }
  };

  const activeFilterCount = countActiveFilters(filters);

  return (
    <>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        style={styles.container}
        contentContainerStyle={styles.content}
      >
        <Menu
          visible={menuVisible}
          onDismiss={() => setMenuVisible(false)}
          anchor={
            <Chip
              icon="plus"
              onPress={() => setMenuVisible(true)}
              style={styles.chip}
            >
              Add Filter
            </Chip>
          }
        >
          <Menu.Item
            onPress={() => openModal("todoStates")}
            title="State"
            disabled={isFilterActive("todoStates")}
          />
          <Menu.Item
            onPress={() => openModal("priority")}
            title="Priority"
            disabled={isFilterActive("priority")}
          />
          <Menu.Item
            onPress={() => openModal("tags")}
            title="Tags"
            disabled={isFilterActive("tags")}
          />
          <Menu.Item
            onPress={() => openModal("categories")}
            title="Category"
            disabled={isFilterActive("categories")}
          />
        </Menu>

        {isFilterActive("todoStates") && (
          <Chip
            onPress={() => openModal("todoStates")}
            onClose={() => clearFilter("todoStates")}
            style={styles.chip}
          >
            {formatFilterLabel("todoStates")}
          </Chip>
        )}

        {isFilterActive("priority") && (
          <Chip
            onPress={() => openModal("priority")}
            onClose={() => clearFilter("priority")}
            style={styles.chip}
          >
            {formatFilterLabel("priority")}
          </Chip>
        )}

        {isFilterActive("tags") && (
          <Chip
            onPress={() => openModal("tags")}
            onClose={() => clearFilter("tags")}
            style={styles.chip}
          >
            {formatFilterLabel("tags")}
          </Chip>
        )}

        {isFilterActive("categories") && (
          <Chip
            onPress={() => openModal("categories")}
            onClose={() => clearFilter("categories")}
            style={styles.chip}
          >
            {formatFilterLabel("categories")}
          </Chip>
        )}

        {activeFilterCount >= 2 && (
          <Chip
            icon="close-circle"
            onPress={clearAllFilters}
            style={styles.chip}
            textStyle={{ color: theme.colors.error }}
          >
            Clear All
          </Chip>
        )}
      </ScrollView>

      <FilterModal
        visible={modalType === "todoStates"}
        onDismiss={() => setModalType(null)}
        filterType="todoStates"
        filterOptions={filterOptions}
        selectedValues={filters.todoStates}
        onSelectValues={setTodoStates}
      />

      <FilterModal
        visible={modalType === "priority"}
        onDismiss={() => setModalType(null)}
        filterType="priority"
        filterOptions={filterOptions}
        selectedThreshold={filters.priorityThreshold}
        onSelectThreshold={setPriorityThreshold}
      />

      <FilterModal
        visible={modalType === "tags"}
        onDismiss={() => setModalType(null)}
        filterType="tags"
        filterOptions={filterOptions}
        selectedValues={filters.tags}
        onSelectValues={setTags}
      />

      <FilterModal
        visible={modalType === "categories"}
        onDismiss={() => setModalType(null)}
        filterType="categories"
        filterOptions={filterOptions}
        selectedValues={filters.categories}
        onSelectValues={setCategories}
      />
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    maxHeight: 50,
  },
  content: {
    paddingHorizontal: 16,
    paddingVertical: 8,
    gap: 8,
    flexDirection: "row",
    alignItems: "center",
  },
  chip: {
    marginRight: 4,
  },
});
```

**Step 2: Run type check**

```bash
cd mova && npx tsc --noEmit
```

**Step 3: Commit**

```bash
git add mova/components/FilterBar.tsx
git commit -m "feat: add FilterBar component with filter chips"
```

---

## Task 10: Integrate FilterBar into Search Screen

**Files:**
- Modify: `mova/app/(tabs)/search.tsx`

**Step 1: Add imports**

```typescript
import { FilterBar } from "@/components/FilterBar";
import { useFilteredTodos } from "@/hooks/useFilteredTodos";
import { useFilters } from "@/context/FilterContext";
```

**Step 2: Use the hook and add FilterBar**

Inside SearchScreen, after the existing filter logic, add:

```typescript
// After: const { apiUrl, username, password } = useAuth();
const { hasActiveFilters: hasGlobalFilters, clearAllFilters } = useFilters();

// Apply global filters to already text-filtered results
const globallyFilteredTodos = useFilteredTodos(filteredTodos);
```

Update the empty state message to show filter-aware text and add FilterBar below searchContainer:

In the JSX, add FilterBar after the searchContainer View:

```tsx
<View style={styles.searchContainer}>
  {/* existing Searchbar and IconButton */}
</View>
<FilterBar />
```

Update the FlatList data prop and empty state:

```tsx
data={globallyFilteredTodos}
```

Update empty state to be filter-aware:

```tsx
) : globallyFilteredTodos.length === 0 ? (
  <View testID="searchEmptyView" style={styles.centered}>
    <Text variant="bodyLarge" style={{ opacity: 0.6 }}>
      {searchQuery || hasGlobalFilters
        ? "No matching todos"
        : "No todos found"}
    </Text>
    {hasGlobalFilters && (
      <Button onPress={clearAllFilters} style={{ marginTop: 8 }}>
        Clear Filters
      </Button>
    )}
  </View>
```

Add Button import at top:

```typescript
import { Button } from "react-native-paper";
// (already has other react-native-paper imports, just add Button)
```

**Step 3: Run type check**

```bash
cd mova && npx tsc --noEmit
```

**Step 4: Commit**

```bash
git add mova/app/\(tabs\)/search.tsx
git commit -m "feat: integrate FilterBar into Search screen"
```

---

## Task 11: Integrate FilterBar into Agenda Screen

**Files:**
- Modify: `mova/app/(tabs)/index.tsx`

**Step 1: Read current file and add imports**

Add these imports:

```typescript
import { FilterBar } from "@/components/FilterBar";
import { useFilteredTodos } from "@/hooks/useFilteredTodos";
import { useFilters } from "@/context/FilterContext";
```

**Step 2: Use the hook**

Add inside the component:

```typescript
const { hasActiveFilters, clearAllFilters } = useFilters();
const filteredEntries = useFilteredTodos(entries);
```

**Step 3: Add FilterBar to JSX**

Add `<FilterBar />` after the date navigation section.

Update FlatList/entry rendering to use `filteredEntries` instead of `entries`.

Add filter-aware empty state similar to search screen.

**Step 4: Run type check**

```bash
cd mova && npx tsc --noEmit
```

**Step 5: Commit**

```bash
git add mova/app/\(tabs\)/index.tsx
git commit -m "feat: integrate FilterBar into Agenda screen"
```

---

## Task 12: Integrate FilterBar into Custom Views Screen

**Files:**
- Modify: `mova/app/(tabs)/views.tsx`

**Step 1: Add imports**

```typescript
import { FilterBar } from "@/components/FilterBar";
import { useFilteredTodos } from "@/hooks/useFilteredTodos";
import { useFilters } from "@/context/FilterContext";
```

**Step 2: Use the hook**

Add inside the component when viewing entries:

```typescript
const { hasActiveFilters, clearAllFilters } = useFilters();
const filteredEntries = useFilteredTodos(entries);
```

**Step 3: Add FilterBar when viewing entries**

Add `<FilterBar />` below the view title/header when entries are being displayed.

Update entry list to use `filteredEntries`.

**Step 4: Run type check**

```bash
cd mova && npx tsc --noEmit
```

**Step 5: Commit**

```bash
git add mova/app/\(tabs\)/views.tsx
git commit -m "feat: integrate FilterBar into Custom Views screen"
```

---

## Task 13: Run Full Test Suite

**Step 1: Run unit tests**

```bash
cd mova && yarn test --testPathPattern=unit
```

Expected: All tests pass.

**Step 2: Run type check**

```bash
cd mova && npx tsc --noEmit
```

Expected: No type errors.

**Step 3: Run linter**

```bash
cd mova && yarn lint
```

Expected: No errors (warnings OK).

---

## Task 14: Final Commit and Summary

**Step 1: Review all changes**

```bash
git log --oneline feature/filter-narrowing ^master
```

**Step 2: Create summary commit if needed**

If any files were missed, add and commit them.

**Step 3: Document completion**

The feature is complete when:
- Backend returns category field on all todos
- Backend has /filter-options endpoint
- FilterContext manages global filter state
- FilterBar shows on all three screens
- Filters persist across app restarts
- Empty states show filter-aware messaging
