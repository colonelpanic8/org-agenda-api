"""Tests for arbitrary properties support in org-agenda-api."""


class TestPropertiesInGetTodos:
    """Tests for properties field in GET /get-all-todos endpoint."""

    def test_todo_includes_properties_field(self, api):
        """Each TODO item should include a properties field."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        # Find the item with custom properties
        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None, (
            "Should find the 'Task with custom properties' item"
        )
        assert "properties" in custom_item, "Item should have a 'properties' field"

    def test_properties_contains_custom_fields(self, api):
        """Properties should contain arbitrary custom fields from the drawer."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None

        properties = custom_item.get("properties", {})
        assert properties is not None, "Properties should not be None"

        # Check for our custom fields
        assert "CUSTOM_FIELD" in properties, (
            f"Should have CUSTOM_FIELD, got: {properties.keys()}"
        )
        assert properties["CUSTOM_FIELD"] == "my-custom-value"
        assert properties["CATEGORY"] == "testing", (
            "An explicitly defined CATEGORY should remain in properties"
        )

    def test_properties_contains_effort(self, api):
        """Properties should include EFFORT field."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None

        properties = custom_item.get("properties", {})
        assert "EFFORT" in properties
        assert properties["EFFORT"] == "2:00"

    def test_todo_includes_top_level_effort_field(self, api):
        """TODO items should expose Org effort as a first-class field."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None
        assert custom_item.get("effort") == "2:00"

    def test_properties_contains_energy_and_context(self, api):
        """Properties should include ENERGY and CONTEXT fields."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None

        properties = custom_item.get("properties", {})
        assert "ENERGY" in properties
        assert properties["ENERGY"] == "high"
        assert "CONTEXT" in properties
        assert properties["CONTEXT"] == "@computer"

    def test_items_without_drawer_have_no_synthetic_properties(self, api):
        """Items without a property drawer should not expose computed properties."""
        response = api.get_all_todos()
        todos = response.json()["todos"]

        # Find an item without explicit properties
        simple_item = next(
            (item for item in todos if "Buy groceries" in item.get("title", "")),
            None,
        )
        assert simple_item is not None

        assert "properties" in simple_item
        assert simple_item["properties"] in ({}, None)


class TestUpdateProperties:
    """Tests for updating arbitrary properties via POST /update endpoint."""

    def test_can_set_custom_property(self, api):
        """Should be able to set a custom property on a TODO."""
        # Get the custom properties item
        response = api.get_all_todos()
        todos = response.json()["todos"]
        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None

        # Update with a new custom property
        update_response = api.update_todo(
            custom_item, {"properties": {"NEW_PROPERTY": "new-value"}}
        )
        assert update_response.status_code == 200
        result = update_response.json()
        assert result.get("status") == "updated"

        # Verify the property was set
        response = api.get_all_todos()
        todos = response.json()["todos"]
        updated_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert updated_item is not None
        properties = updated_item.get("properties", {})
        assert "NEW_PROPERTY" in properties
        assert properties["NEW_PROPERTY"] == "new-value"

    def test_can_update_existing_property(self, api):
        """Should be able to update an existing property value."""
        response = api.get_all_todos()
        todos = response.json()["todos"]
        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None

        # Update the ENERGY property
        update_response = api.update_todo(
            custom_item, {"properties": {"ENERGY": "low"}}
        )
        assert update_response.status_code == 200

        # Verify the update
        response = api.get_all_todos()
        todos = response.json()["todos"]
        updated_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        properties = updated_item.get("properties", {})
        assert properties["ENERGY"] == "low"

    def test_can_remove_property_with_empty_value(self, api):
        """Should be able to remove a property by setting it to empty string."""
        response = api.get_all_todos()
        todos = response.json()["todos"]
        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None

        # First add a property we can remove
        api.update_todo(custom_item, {"properties": {"REMOVABLE": "will-be-removed"}})

        # Now remove it
        update_response = api.update_todo(
            custom_item, {"properties": {"REMOVABLE": ""}}
        )
        assert update_response.status_code == 200

        # Verify removal
        response = api.get_all_todos()
        todos = response.json()["todos"]
        updated_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        properties = updated_item.get("properties", {})
        # Property should either not exist or be empty
        assert properties.get("REMOVABLE", "") == ""

    def test_can_set_multiple_properties_at_once(self, api):
        """Should be able to set multiple properties in a single update."""
        response = api.get_all_todos()
        todos = response.json()["todos"]
        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None

        # Set multiple properties
        update_response = api.update_todo(
            custom_item,
            {
                "properties": {
                    "PROP_A": "value-a",
                    "PROP_B": "value-b",
                    "PROP_C": "value-c",
                }
            },
        )
        assert update_response.status_code == 200

        # Verify all were set
        response = api.get_all_todos()
        todos = response.json()["todos"]
        updated_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        properties = updated_item.get("properties", {})
        assert properties["PROP_A"] == "value-a"
        assert properties["PROP_B"] == "value-b"
        assert properties["PROP_C"] == "value-c"

    def test_can_add_property_to_item_without_drawer(self, api):
        """Should be able to add a property to an item that has no PROPERTIES drawer.

        org-entry-put should create the drawer automatically.
        """
        response = api.get_all_todos()
        todos = response.json()["todos"]

        # Find an item without a properties drawer (Buy groceries has none)
        simple_item = next(
            (item for item in todos if "Buy groceries" in item.get("title", "")),
            None,
        )
        assert simple_item is not None, "Should find 'Buy groceries' item"

        # Verify it has minimal/no custom properties initially
        initial_props = simple_item.get("properties") or {}
        assert "TEST_NEW_PROP" not in initial_props

        # Add a property - this should create the PROPERTIES drawer
        update_response = api.update_todo(
            simple_item, {"properties": {"TEST_NEW_PROP": "created-drawer"}}
        )
        assert update_response.status_code == 200
        result = update_response.json()
        assert result.get("status") == "updated"

        # Verify the property was set and drawer was created
        response = api.get_all_todos()
        todos = response.json()["todos"]
        updated_item = next(
            (item for item in todos if "Buy groceries" in item.get("title", "")),
            None,
        )
        assert updated_item is not None
        properties = updated_item.get("properties", {})
        assert "TEST_NEW_PROP" in properties
        assert properties["TEST_NEW_PROP"] == "created-drawer"


class TestUpdateEffort:
    """Tests for Org effort support via POST /update."""

    def test_can_update_effort_via_top_level_field(self, api):
        """Should update effort using the dedicated effort field."""
        response = api.get_all_todos()
        todos = response.json()["todos"]
        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None

        update_response = api.update_todo(custom_item, {"effort": "1:30"})
        assert update_response.status_code == 200
        assert update_response.json().get("status") == "updated"

        response = api.get_all_todos()
        todos = response.json()["todos"]
        updated_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert updated_item is not None
        assert updated_item.get("effort") == "1:30"
        assert updated_item.get("properties", {}).get("EFFORT") == "1:30"

    def test_can_clear_effort_via_top_level_field(self, api):
        """Should clear effort when the dedicated effort field is null."""
        response = api.get_all_todos()
        todos = response.json()["todos"]
        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None

        update_response = api.update_todo(custom_item, {"effort": None})
        assert update_response.status_code == 200
        assert update_response.json().get("status") == "updated"

        response = api.get_all_todos()
        todos = response.json()["todos"]
        updated_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert updated_item is not None
        assert updated_item.get("effort") is None
        assert updated_item.get("properties", {}).get("EFFORT") is None

    def test_top_level_effort_overrides_properties_effort(self, api):
        """Dedicated effort field should win over properties.EFFORT when both are sent."""
        response = api.get_all_todos()
        todos = response.json()["todos"]
        custom_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert custom_item is not None

        update_response = api.update_todo(
            custom_item,
            {"effort": "0:45", "properties": {"EFFORT": "3:00"}},
        )
        assert update_response.status_code == 200
        assert update_response.json().get("status") == "updated"

        response = api.get_all_todos()
        todos = response.json()["todos"]
        updated_item = next(
            (
                item
                for item in todos
                if "custom properties" in item.get("title", "").lower()
            ),
            None,
        )
        assert updated_item is not None
        assert updated_item.get("effort") == "0:45"
        assert updated_item.get("properties", {}).get("EFFORT") == "0:45"
