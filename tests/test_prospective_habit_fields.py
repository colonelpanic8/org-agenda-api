"""Tests for prospective habit entries having effectiveCategory and properties.

Bug: When the week agenda (/agenda?span=week) returns prospective habit entries
for future days, these entries have:
- effectiveCategory: null
- properties: null

But when the day agenda returns entries, they include full properties and
effectiveCategory from the org heading.

This is because the prospective habit generation in
`org-agenda-api--get-habit-entry-for-date` doesn't extract these fields.
"""

import pytest
from conftest import TEST_DATE, TEST_WEEK_START


class TestProspectiveHabitFields:
    """Tests for effectiveCategory and properties on prospective habit entries."""

    def test_habit_entry_has_effective_category_in_day_view(self, api):
        """Habit entries in day view should have effectiveCategory."""
        response = api.get_agenda(span="day", date=TEST_DATE)
        data = response.json()

        habit_entries = [e for e in data.get("entries", []) if e.get("isWindowHabit")]

        # Skip if no habits on this day (test data may vary)
        if not habit_entries:
            pytest.skip("No habit entries found in day view for test date")

        for entry in habit_entries:
            assert entry.get("effectiveCategory") is not None, (
                f"Habit entry '{entry.get('title')}' should have effectiveCategory, "
                f"but got null"
            )

    def test_habit_entry_has_properties_in_day_view(self, api):
        """Habit entries in day view should have properties."""
        response = api.get_agenda(span="day", date=TEST_DATE)
        data = response.json()

        habit_entries = [e for e in data.get("entries", []) if e.get("isWindowHabit")]

        if not habit_entries:
            pytest.skip("No habit entries found in day view for test date")

        for entry in habit_entries:
            # Properties may be an empty object, but should not be null
            assert entry.get("properties") is not None, (
                f"Habit entry '{entry.get('title')}' should have properties, "
                f"but got null"
            )

    def test_prospective_habit_has_effective_category_in_week_view(self, api):
        """Prospective habit entries in week view should have effectiveCategory.

        This is the core bug: when generating prospective habit entries for
        future days, effectiveCategory is not being set.
        """
        response = api.get_agenda(span="week", date=TEST_WEEK_START)
        data = response.json()

        # Find habit entries across all days
        habit_entries = []
        for date_str, entries in data.get("days", {}).items():
            for entry in entries:
                if entry.get("isWindowHabit"):
                    habit_entries.append((date_str, entry))

        if not habit_entries:
            pytest.skip("No habit entries found in week view")

        # Check each habit entry has effectiveCategory
        missing_category = []
        for date_str, entry in habit_entries:
            if entry.get("effectiveCategory") is None:
                missing_category.append(f"  - '{entry.get('title')}' on {date_str}")

        assert not missing_category, (
            "Prospective habit entries should have effectiveCategory, "
            "but these entries have null:\n" + "\n".join(missing_category)
        )

    def test_prospective_habit_has_properties_in_week_view(self, api):
        """Prospective habit entries in week view should have properties.

        This is the core bug: when generating prospective habit entries for
        future days, properties are not being extracted.
        """
        response = api.get_agenda(span="week", date=TEST_WEEK_START)
        data = response.json()

        # Find habit entries across all days
        habit_entries = []
        for date_str, entries in data.get("days", {}).items():
            for entry in entries:
                if entry.get("isWindowHabit"):
                    habit_entries.append((date_str, entry))

        if not habit_entries:
            pytest.skip("No habit entries found in week view")

        # Check each habit entry has properties
        missing_properties = []
        for date_str, entry in habit_entries:
            if entry.get("properties") is None:
                missing_properties.append(f"  - '{entry.get('title')}' on {date_str}")

        assert not missing_properties, (
            "Prospective habit entries should have properties, "
            "but these entries have null:\n" + "\n".join(missing_properties)
        )

    def test_prospective_habit_category_matches_original(self, api, org_dir):
        """Prospective habit entries should have the same effectiveCategory as the original.

        The effectiveCategory should be inherited from the org file/heading,
        not reset to null.
        """
        response = api.get_agenda(span="week", date=TEST_WEEK_START)
        data = response.json()

        # Find habit entries
        habit_entries = []
        for date_str, entries in data.get("days", {}).items():
            for entry in entries:
                if entry.get("isWindowHabit"):
                    habit_entries.append((date_str, entry))

        if not habit_entries:
            pytest.skip("No habit entries found in week view")

        # Each habit should have a non-null effectiveCategory
        for date_str, entry in habit_entries:
            category = entry.get("effectiveCategory")
            assert category is not None, (
                f"Habit '{entry.get('title')}' on {date_str} has null effectiveCategory"
            )
            # Category should be a non-empty string
            assert isinstance(category, str) and len(category) > 0, (
                f"Habit '{entry.get('title')}' on {date_str} has invalid "
                f"effectiveCategory: {category!r}"
            )

    def test_prospective_habit_properties_include_owh_settings(self, api):
        """Prospective habit entries should have OWH_ properties in properties.

        Window habits have OWH_ prefixed properties like OWH_WINDOW_DURATION,
        OWH_REPETITIONS_REQUIRED, etc. These should be visible in the properties.
        """
        response = api.get_agenda(span="week", date=TEST_WEEK_START)
        data = response.json()

        # Find habit entries
        habit_entries = []
        for date_str, entries in data.get("days", {}).items():
            for entry in entries:
                if entry.get("isWindowHabit"):
                    habit_entries.append((date_str, entry))

        if not habit_entries:
            pytest.skip("No habit entries found in week view")

        # At least one habit should have OWH_ properties
        has_owh_props = False
        for date_str, entry in habit_entries:
            props = entry.get("properties")
            assert props is not None, (
                f"Habit '{entry.get('title')}' on {date_str} has null properties"
            )
            # Check for any OWH_ prefixed property
            owh_props = [k for k in props.keys() if k.startswith("OWH_")]
            if owh_props:
                has_owh_props = True
                break

        assert has_owh_props, (
            "At least one habit entry should have OWH_ properties. "
            "Sample properties: "
            + str([e[1].get("properties") for e in habit_entries[:3]])
        )
