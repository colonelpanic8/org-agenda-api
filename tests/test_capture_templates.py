"""Integration tests for capture template API."""



class TestGetTemplates:
    """Tests for GET /capture-templates endpoint."""

    def test_returns_200(self, api):
        """Endpoint should return 200 OK."""
        response = api.get("/capture-templates")
        assert response.status_code == 200

    def test_returns_json_object(self, api):
        """Endpoint should return a JSON object."""
        response = api.get("/capture-templates")
        data = response.json()
        assert isinstance(data, dict)

    def test_returns_registered_templates(self, api):
        """Should return templates that were registered for API use."""
        response = api.get("/capture-templates")
        data = response.json()

        # We configure a "todo" template in the test setup
        assert "todo" in data

        template = data["todo"]
        assert "name" in template
        assert "prompts" in template

    def test_template_includes_prompt_info(self, api):
        """Template should list its interactive prompts with types."""
        response = api.get("/capture-templates")
        data = response.json()

        # The "todo" template has a Title prompt
        todo_template = data.get("todo", {})
        prompts = todo_template.get("prompts", [])

        # Should have at least the Title prompt
        prompt_names = [p.get("name") for p in prompts]
        assert "Title" in prompt_names


class TestCaptureWithTemplate:
    """Tests for POST /capture endpoint."""

    def test_returns_200(self, api):
        """Endpoint should return 200 OK on successful capture."""
        response = api.post("/capture", json={
            "template": "todo",
            "values": {"Title": "Test capture"}
        })
        assert response.status_code == 200

    def test_returns_confirmation(self, api):
        """Endpoint should return confirmation with details."""
        response = api.post("/capture", json={
            "template": "todo",
            "values": {"Title": "Confirmation test"}
        })
        data = response.json()

        assert data.get("status") == "created"
        assert "template" in data
        assert data["template"] == "todo"

    def test_captured_entry_appears_in_todos(self, api):
        """Captured entry should appear in get-all-todos."""
        unique_title = "Unique capture test 98765"

        # Capture using template
        capture_response = api.post("/capture", json={
            "template": "todo",
            "values": {"Title": unique_title}
        })
        assert capture_response.status_code == 200

        # Verify it appears in the list
        list_response = api.get_all_todos()
        todos = list_response.json()["todos"]

        titles = [item.get("title", "") for item in todos]
        matching = [t for t in titles if unique_title in t]

        assert len(matching) > 0, f"Captured entry not found. Titles: {titles}"

    def test_captured_entry_in_correct_file(self, api, org_dir):
        """Captured entry should be written to the template's target file."""
        unique_title = "File location test 11111"

        api.post("/capture", json={
            "template": "todo",
            "values": {"Title": unique_title}
        })

        # Check the inbox file (default target for todo template)
        inbox_path = org_dir / "inbox.org"
        content = inbox_path.read_text()

        assert unique_title in content, f"Entry not found in inbox:\n{content}"

    def test_error_on_unknown_template(self, api):
        """Should return error for unknown template key."""
        response = api.post("/capture", json={
            "template": "nonexistent",
            "values": {"Title": "Test"}
        })

        # simple-httpd returns 200 with error in body
        data = response.json()
        assert data.get("status") == "error"
        assert "Unknown template" in data.get("message", "")

    def test_error_on_missing_required_prompt(self, api):
        """Should return error if required prompt value is missing."""
        response = api.post("/capture", json={
            "template": "todo",
            "values": {}  # Missing required "Title"
        })

        # simple-httpd returns 200 with error in body
        data = response.json()
        assert data.get("status") == "error"
        assert "Missing required" in data.get("message", "")


class TestCaptureWithDatePrompt:
    """Tests for templates with date prompts (%^t)."""

    def test_accepts_iso_date(self, api):
        """Should accept ISO format dates for %^t prompts."""
        response = api.post("/capture", json={
            "template": "scheduled-todo",
            "values": {
                "Title": "Date test todo",
                "When": "2024-06-20"
            }
        })
        assert response.status_code == 200

    def test_date_appears_in_entry(self, api, org_dir):
        """Date should be converted to org timestamp in entry."""
        unique_title = "Scheduled date test 22222"

        api.post("/capture", json={
            "template": "scheduled-todo",
            "values": {
                "Title": unique_title,
                "When": "2024-06-20"
            }
        })

        # Check that the date appears as an org timestamp
        inbox_path = org_dir / "inbox.org"
        content = inbox_path.read_text()

        assert unique_title in content
        # Should have an org timestamp somewhere
        assert "2024-06-20" in content or "<2024-06-20" in content


class TestCaptureWithTags:
    """Tests for templates with tag prompts (%^g)."""

    def test_accepts_tags_list(self, api):
        """Should accept a list of tags for %^g prompts."""
        response = api.post("/capture", json={
            "template": "tagged-todo",
            "values": {
                "Title": "Tagged test todo",
                "Tags": ["work", "urgent"]
            }
        })
        assert response.status_code == 200

    def test_tags_appear_in_entry(self, api, org_dir):
        """Tags should appear in the captured entry."""
        unique_title = "Tag test 33333"

        api.post("/capture", json={
            "template": "tagged-todo",
            "values": {
                "Title": unique_title,
                "Tags": ["work", "urgent"]
            }
        })

        inbox_path = org_dir / "inbox.org"
        content = inbox_path.read_text()

        assert unique_title in content
        # Tags should appear in org format
        assert ":work:" in content
        assert ":urgent:" in content


class TestCaptureWithAutoFields:
    """Tests that automatic template fields work (%t, %U, etc)."""

    def test_auto_timestamp_filled(self, api, org_dir):
        """Templates with %U should have timestamp auto-filled."""
        unique_title = "Auto timestamp test 44444"

        api.post("/capture", json={
            "template": "note",  # Uses %U for inactive timestamp
            "values": {"Title": unique_title}
        })

        inbox_path = org_dir / "inbox.org"
        content = inbox_path.read_text()

        assert unique_title in content
        # Should have an inactive timestamp [2024-...]
        assert "[2024-" in content or "[2026-" in content  # Account for test date


class TestCaptureWithSexpExpansion:
    """Tests for %(sexp) template expansion like %(org-id-new)."""

    def test_org_id_new_generates_uuid(self, api, org_dir):
        """Templates with %(org-id-new) should generate a unique UUID."""
        unique_title = "UUID test 55555"

        api.post("/capture", json={
            "template": "todo-with-id",
            "values": {"Title": unique_title}
        })

        inbox_path = org_dir / "inbox.org"
        content = inbox_path.read_text()

        assert unique_title in content
        # Should have :ID: property with a UUID (8-4-4-4-12 hex format)
        assert ":ID:" in content
        # UUID pattern: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        import re
        uuid_pattern = r':ID:\s+[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        assert re.search(uuid_pattern, content), f"No UUID found in content:\n{content}"

    def test_org_id_not_literal(self, api, org_dir):
        """%(org-id-new) should NOT appear literally in output."""
        unique_title = "Literal test 55556"

        api.post("/capture", json={
            "template": "todo-with-id",
            "values": {"Title": unique_title}
        })

        inbox_path = org_dir / "inbox.org"
        content = inbox_path.read_text()

        # The literal %(org-id-new) should NOT appear - it should be expanded
        assert "%(org-id-new)" not in content, \
            f"%(org-id-new) was not expanded in content:\n{content}"

    def test_format_time_string_generates_date(self, api, org_dir):
        """Templates with %(format-time-string ...) should generate formatted date."""
        unique_title = "Format time test 66666"

        api.post("/capture", json={
            "template": "scheduled-auto",
            "values": {"Title": unique_title}
        })

        inbox_path = org_dir / "inbox.org"
        content = inbox_path.read_text()

        assert unique_title in content
        # Should have SCHEDULED with an actual date, not the literal expression
        assert "%(format-time-string" not in content, \
            f"%(format-time-string ...) was not expanded in content:\n{content}"
        # Should have a proper org timestamp
        assert "SCHEDULED: <" in content
        # The date should be in YYYY-MM-DD format
        import re
        scheduled_pattern = r'SCHEDULED:\s+<\d{4}-\d{2}-\d{2}'
        assert re.search(scheduled_pattern, content), \
            f"No proper SCHEDULED date found in content:\n{content}"

    def test_multiple_sexp_expressions(self, api, org_dir):
        """Templates with multiple %(sexp) should all be expanded."""
        unique_title = "Multi sexp test 77777"

        api.post("/capture", json={
            "template": "full-template",
            "values": {"Title": unique_title}
        })

        inbox_path = org_dir / "inbox.org"
        content = inbox_path.read_text()

        assert unique_title in content

        # None of the sexp expressions should appear literally
        assert "%(org-id-new)" not in content
        assert "%(format-time-string" not in content
        assert "%(number-to-string" not in content

        # Should have actual expanded values
        import re
        # UUID for :ID:
        uuid_pattern = r':ID:\s+[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        assert re.search(uuid_pattern, content), f"No UUID found in content:\n{content}"
        # SCHEDULED date
        assert "SCHEDULED: <" in content
        # EFFORT should be "30" (from %(number-to-string 30))
        assert ":EFFORT:" in content
        effort_pattern = r':EFFORT:\s+30'
        assert re.search(effort_pattern, content), f"EFFORT not set to 30 in content:\n{content}"

    def test_each_capture_gets_unique_id(self, api, org_dir):
        """Each capture should generate a different UUID."""
        import re

        # Capture two items
        api.post("/capture", json={
            "template": "todo-with-id",
            "values": {"Title": "First UUID item 88881"}
        })
        api.post("/capture", json={
            "template": "todo-with-id",
            "values": {"Title": "Second UUID item 88882"}
        })

        inbox_path = org_dir / "inbox.org"
        content = inbox_path.read_text()

        # Find all UUIDs
        uuid_pattern = r':ID:\s+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
        uuids = re.findall(uuid_pattern, content)

        # Should have at least 2 UUIDs (one for each capture)
        assert len(uuids) >= 2, f"Expected at least 2 UUIDs, found {len(uuids)}"

        # The UUIDs should be unique
        unique_uuids = set(uuids)
        assert len(unique_uuids) >= 2, \
            f"Expected unique UUIDs but found duplicates: {uuids}"
