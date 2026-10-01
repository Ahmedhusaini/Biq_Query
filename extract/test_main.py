"""Unit tests for the loader, with HubSpot and BigQuery faked. Run: python -m pytest extract/"""
from types import SimpleNamespace

import main


class FakeResponse:
    def __init__(self, status, payload=None):
        self.status_code, self._payload = status, payload or {}

    def json(self):
        return self._payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(self.status_code)


class FakeSession:
    """Returns queued responses in order and records every request."""
    def __init__(self, responses):
        self.responses, self.calls, self.headers = list(responses), [], {}

    def request(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        return self.responses.pop(0)


def contact(cid, modified, archived_at=None):
    rec = {"id": str(cid), "properties": {"email": f"u{cid}@x.com", "lifecyclestage": "lead",
                                          "lastmodifieddate": modified}}
    if archived_at:
        rec["archivedAt"] = archived_at
    return rec


class FakeBQ:
    def __init__(self, watermark):
        self.watermark, self.loaded = watermark, []

    def query(self, sql):
        return SimpleNamespace(result=lambda: [SimpleNamespace(wm=self.watermark)])


def test_pagination_and_watermark(monkeypatch):
    session = FakeSession([
        FakeResponse(200, {"results": [contact(1, "2026-09-01T10:00:00Z")],
                           "paging": {"next": {"after": "1"}}}),
        FakeResponse(200, {"results": [contact(2, "2026-09-01T11:00:00Z")]}),
    ])
    client = main.HubSpotClient("token", session=session)
    rows = list(client.search_modified_since(watermark_ms=123))
    assert [r["id"] for r in rows] == ["1", "2"]
    first_body = session.calls[0][2]["json"]
    assert first_body["filterGroups"][0]["filters"][0] == {
        "propertyName": "lastmodifieddate", "operator": "GTE", "value": "123"}
    assert session.calls[1][2]["json"]["after"] == "1"


def test_retries_on_rate_limit(monkeypatch):
    monkeypatch.setattr(main.time, "sleep", lambda s: None)
    session = FakeSession([FakeResponse(429), FakeResponse(429),
                           FakeResponse(200, {"results": [contact(1, "2026-09-01T10:00:00Z")]})])
    rows = list(main.HubSpotClient("t", session=session).search_modified_since(0))
    assert len(rows) == 1 and len(session.calls) == 3


def test_deleted_contact_uses_archive_time():
    rec = contact(7, "2026-09-01T10:00:00Z", archived_at="2026-09-05T08:00:00Z")
    row = main.flatten(rec, is_deleted=True, loaded_at="now")
    assert row["is_deleted"] is True
    assert row["lastmodifieddate"] == "2026-09-05T08:00:00Z"   # newer -> wins dedup in dbt
    assert row["contact_id"] == 7


def test_sync_end_to_end(monkeypatch):
    loaded = []
    monkeypatch.setattr(main, "load_rows", lambda bq, rows: loaded.extend(rows) or len(rows))
    session = FakeSession([
        FakeResponse(200, {"results": [contact(1, "2026-09-01T10:00:00Z")]}),        # search
        FakeResponse(200, {"results": [contact(2, "2026-08-01T10:00:00Z",           # archived
                                               archived_at="2026-09-02T00:00:00Z"),
                                       contact(3, "2025-01-01T10:00:00Z",           # archived long ago
                                               archived_at="2025-02-01T00:00:00Z")]}),
    ])
    wm = main.to_epoch_ms("2026-08-31T00:00:00Z")
    result = main.sync_contacts(FakeBQ(wm), main.HubSpotClient("t", session=session))
    assert result == {"watermark_ms": wm, "upserted": 1, "archived": 1}
    assert {r["contact_id"] for r in loaded} == {1, 2}
