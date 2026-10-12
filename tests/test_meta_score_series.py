"""Regression tests for bounded, advancing meta-score series requests."""

import pytest


@pytest.mark.parametrize("step", ["0", "-1", "abc", "1.5", "1day", ""])
def test_series_rejects_invalid_steps_without_blocking_server(api, step):
    response = api.get(
        "/meta-score-series",
        params={"start": "2024-06-15", "end": "2024-06-15", "step": step},
        timeout=2,
    )
    data = response.json()
    assert data["status"] == "error"
    assert "positive integer" in data["message"]
    assert api.get("/health", timeout=2).status_code == 200


@pytest.mark.parametrize(
    "start,end",
    [
        ("invalid", "2024-06-15"),
        ("2024-06-15", "2024-02-30"),
        ("2024-06-16", "2024-06-15"),
        ("2024-06-15T00:00:00", "2024-06-15"),
        ("2024-06-15", "2044-06-15"),
    ],
)
def test_series_rejects_invalid_or_excessive_ranges(api, start, end):
    data = api.get(
        "/meta-score-series", params={"start": start, "end": end}, timeout=2
    ).json()
    assert data["status"] == "error"
    assert data["message"]


@pytest.mark.parametrize("step", [None, 2])
def test_series_includes_end_date_with_positive_step(api, step):
    params = {"start": "2024-06-15", "end": "2024-06-19"}
    if step is not None:
        params["step"] = step
    data = api.get("/meta-score-series", params=params).json()
    assert data["status"] == "ok"
    assert data["stepDays"] == (step or 1)
    expected = [f"2024-06-{day}" for day in range(15, 20, step or 1)]
    assert [entry["date"] for entry in data["series"]] == expected
