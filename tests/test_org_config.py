"""Tests for the orgConfig block of /metadata.

Clients (e.g. mova) mirror these org-mode settings locally, so they need to
read them over the wire instead of duplicating the elisp configuration.
"""


class TestOrgConfigMetadata:
    def test_metadata_includes_org_config(self, api):
        response = api.get("/metadata")
        assert response.status_code == 200

        org_config = response.json()["orgConfig"]
        assert isinstance(org_config, dict)

    def test_extend_today_until_is_an_hour(self, api):
        """`org-extend-today-until` is reported as a whole hour past midnight."""
        org_config = api.get("/metadata").json()["orgConfig"]

        assert "extendTodayUntil" in org_config
        value = org_config["extendTodayUntil"]
        assert isinstance(value, int)
        assert 0 <= value <= 23

    def test_extend_today_until_defaults_to_midnight(self, api):
        """The test server leaves the variable at its org default of 0."""
        org_config = api.get("/metadata").json()["orgConfig"]
        assert org_config["extendTodayUntil"] == 0
