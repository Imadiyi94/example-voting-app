"""End-to-end integration tests for Capstone 1 - The Voting App.

These tests exercise the full data path:
    vote -> redis -> worker -> postgres -> result

They expect the docker-compose stack to be running locally or in CI, with:
    VOTE_URL   (default http://localhost:5000)
    RESULT_URL (default http://localhost:5001)
"""

import os
import time

import pytest
import requests

VOTE_URL = os.getenv("VOTE_URL", "http://localhost:5000").rstrip("/")
RESULT_URL = os.getenv("RESULT_URL", "http://localhost:5001").rstrip("/")
TIMEOUT = int(os.getenv("HTTP_TIMEOUT", "10"))
PROPAGATION_TIMEOUT = int(os.getenv("PROPAGATION_TIMEOUT", "60"))


def _get(path, base=VOTE_URL, **kwargs):
    return requests.get(f"{base}{path}", timeout=TIMEOUT, **kwargs)


def _votes():
    response = _get("/api/votes", base=RESULT_URL)
    response.raise_for_status()
    return response.json()


@pytest.fixture(scope="session", autouse=True)
def services_ready():
    """Wait until both frontends report healthy before running any test."""
    deadline = time.time() + 120
    last_error = None
    while time.time() < deadline:
        try:
            vote = _get("/health")
            result = _get("/health", base=RESULT_URL)
            if vote.status_code == 200 and result.status_code == 200:
                return
        except requests.RequestException as exc:  # pragma: no cover - timing dependent
            last_error = exc
        time.sleep(3)
    pytest.fail(f"Services did not become healthy in time: {last_error}")


def test_vote_health_reports_redis_connection():
    response = _get("/health")
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "healthy"
    assert payload["redis"] == "connected"


def test_result_health_reports_database_connection():
    response = _get("/health", base=RESULT_URL)
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "healthy"
    assert payload["database"] == "connected"


def test_vote_page_is_served():
    response = _get("/")
    assert response.status_code == 200
    assert "Cats" in response.text and "Dogs" in response.text


def test_result_page_is_served():
    response = _get("/", base=RESULT_URL)
    assert response.status_code == 200
    assert "text/html" in response.headers.get("Content-Type", "")


def test_invalid_vote_is_rejected():
    response = requests.post(
        f"{VOTE_URL}/vote", json={"vote": "Birds"}, timeout=TIMEOUT
    )
    assert response.status_code == 400
    assert response.json()["success"] is False


def test_malformed_vote_is_rejected():
    response = requests.post(f"{VOTE_URL}/vote", json={}, timeout=TIMEOUT)
    assert response.status_code == 400


@pytest.mark.parametrize("choice", ["Cats", "Dogs"])
def test_cast_vote_reaches_database_and_result_api(choice):
    """A vote must survive the vote -> redis -> worker -> postgres -> result path."""
    before = _votes().get(choice, 0)

    response = requests.post(
        f"{VOTE_URL}/vote", json={"vote": choice}, timeout=TIMEOUT
    )
    assert response.status_code == 200
    assert response.json()["success"] is True

    deadline = time.time() + PROPAGATION_TIMEOUT
    observed = before
    while time.time() < deadline:
        observed = _votes().get(choice, 0)
        if observed >= before + 1:
            return
        time.sleep(2)

    pytest.fail(
        f"Vote for {choice} was not persisted within {PROPAGATION_TIMEOUT}s "
        f"(before={before}, observed={observed})"
    )
