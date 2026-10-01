"""
HubSpot -> BigQuery incremental loader, deployable as a Google Cloud Function
(HTTP-triggered by Cloud Scheduler, e.g. every hour).

Design (the answer to "how would you build the HubSpot -> BigQuery pipeline?"):

  1. Watermark   read max(lastmodifieddate) already in raw.hubspot_contacts
  2. Extract     HubSpot CRM Search API, filter lastmodifieddate >= watermark,
                 sorted ascending, paged with `after` (100 rows/page)
  3. Load        append rows to raw.hubspot_contacts (append-only, never update)
  4. Transform   dbt staging dedups to the latest version per contact_id
                 (see models/staging/hubspot/stg_hubspot__contacts.sql)

Why append-only + dedup in dbt:
  * the load is idempotent: re-running after a failure just re-appends
    rows that dbt deduplicates, so nothing is lost or double counted
  * raw keeps full history for debugging and replays
  * ">=" on the watermark (not ">") means records modified in the same
    second as the last run are not skipped; duplicates are harmless

Other points:
  * HubSpot Search returns at most 10,000 results per query -> when we hit that,
    we restart the search from the last seen lastmodifieddate
  * 429 rate limits -> exponential backoff with retries
  * deleted/archived contacts are not returned by Search -> fetched separately
    with archived=true and appended with is_deleted = true
  * token comes from an env var (in production: Secret Manager)

Local test without HubSpot/GCP:  python -m pytest extract/test_main.py
"""
from __future__ import annotations

import os
import time
from datetime import datetime, timezone
from typing import Iterator

import requests

HUBSPOT_BASE = "https://api.hubapi.com"
PROPERTIES = ["email", "firstname", "company", "lifecyclestage", "hs_analytics_source",
              "utm_campaign", "createdate", "lastmodifieddate"]
PAGE_SIZE = 100
SEARCH_RESULT_CAP = 10_000
RAW_TABLE = os.environ.get("RAW_CONTACTS_TABLE", "raw.hubspot_contacts")


# ---------------------------------------------------------------- HubSpot client
class HubSpotClient:
    def __init__(self, token: str, session: requests.Session | None = None, max_retries: int = 5):
        self.session = session or requests.Session()
        self.session.headers.update({"Authorization": f"Bearer {token}",
                                     "Content-Type": "application/json"})
        self.max_retries = max_retries

    def _request(self, method: str, path: str, **kwargs) -> dict:
        for attempt in range(self.max_retries):
            resp = self.session.request(method, f"{HUBSPOT_BASE}{path}", timeout=30, **kwargs)
            if resp.status_code == 429 or resp.status_code >= 500:
                time.sleep(min(2 ** attempt, 30))  # backoff: 1, 2, 4, 8, 16s
                continue
            resp.raise_for_status()
            return resp.json()
        raise RuntimeError(f"HubSpot {method} {path} failed after {self.max_retries} retries")

    def search_modified_since(self, watermark_ms: int) -> Iterator[dict]:
        """Yield all contacts with lastmodifieddate >= watermark, oldest first."""
        while True:
            after, fetched, last_seen_ms = None, 0, watermark_ms
            while True:
                body = {
                    "filterGroups": [{"filters": [{
                        "propertyName": "lastmodifieddate", "operator": "GTE",
                        "value": str(watermark_ms)}]}],
                    "sorts": [{"propertyName": "lastmodifieddate", "direction": "ASCENDING"}],
                    "properties": PROPERTIES,
                    "limit": PAGE_SIZE,
                }
                if after:
                    body["after"] = after
                page = self._request("POST", "/crm/v3/objects/contacts/search", json=body)
                for rec in page.get("results", []):
                    fetched += 1
                    last_seen_ms = to_epoch_ms(rec["properties"]["lastmodifieddate"])
                    yield rec
                after = page.get("paging", {}).get("next", {}).get("after")
                if not after:
                    return  # all results read
                if fetched + PAGE_SIZE > SEARCH_RESULT_CAP:
                    break  # about to hit the 10k cap -> restart from last seen timestamp
            watermark_ms = last_seen_ms

    def list_archived(self, since_ms: int = 0) -> Iterator[dict]:
        """Yield contacts archived (deleted) at or after since_ms."""
        after = None
        while True:
            params = {"archived": "true", "limit": PAGE_SIZE, "properties": ",".join(PROPERTIES)}
            if after:
                params["after"] = after
            page = self._request("GET", "/crm/v3/objects/contacts", params=params)
            for rec in page.get("results", []):
                if rec.get("archivedAt") and to_epoch_ms(rec["archivedAt"]) >= since_ms:
                    yield rec
            after = page.get("paging", {}).get("next", {}).get("after")
            if not after:
                return


# ---------------------------------------------------------------- transforms
def to_epoch_ms(iso_ts: str) -> int:
    return int(datetime.fromisoformat(iso_ts.replace("Z", "+00:00")).timestamp() * 1000)


def flatten(rec: dict, is_deleted: bool, loaded_at: str) -> dict:
    """HubSpot API object -> flat row matching the raw.hubspot_contacts schema."""
    p = rec.get("properties", {})
    return {
        "contact_id": int(rec["id"]),
        "email": p.get("email"),
        "firstname": p.get("firstname"),
        "company": p.get("company"),
        "lifecyclestage": p.get("lifecyclestage"),
        "hs_analytics_source": p.get("hs_analytics_source"),
        "utm_campaign": p.get("utm_campaign"),
        "createdate": p.get("createdate"),
        # for deleted contacts use the archive time, so in dbt the "deleted" version
        # is the latest one and wins the dedup
        "lastmodifieddate": (rec.get("archivedAt") if is_deleted else None)
                            or p.get("lastmodifieddate") or rec.get("updatedAt"),
        "is_deleted": is_deleted,
        "_loaded_at": loaded_at,
    }


# ---------------------------------------------------------------- BigQuery
def get_watermark_ms(bq) -> int:
    sql = f"select unix_millis(max(cast(lastmodifieddate as timestamp))) as wm from `{RAW_TABLE}`"
    rows = list(bq.query(sql).result())
    return (rows[0].wm or 0) if rows else 0


def load_rows(bq, rows: list[dict]) -> int:
    from google.cloud import bigquery  # imported lazily so unit tests don't need GCP libs

    if not rows:
        return 0
    job = bq.load_table_from_json(
        rows, RAW_TABLE,
        job_config=bigquery.LoadJobConfig(
            write_disposition="WRITE_APPEND",
            schema_update_options=["ALLOW_FIELD_ADDITION"],
        ),
    )
    job.result()  # raises on failure
    return len(rows)


# ---------------------------------------------------------------- entry point
def sync_contacts(bq, hubspot: HubSpotClient, batch_size: int = 5_000) -> dict:
    loaded_at = datetime.now(timezone.utc).isoformat()
    watermark = get_watermark_ms(bq)
    batch, total = [], 0
    for rec in hubspot.search_modified_since(watermark):
        batch.append(flatten(rec, is_deleted=False, loaded_at=loaded_at))
        if len(batch) >= batch_size:  # load in batches to bound memory
            total += load_rows(bq, batch)
            batch = []
    total += load_rows(bq, batch)

    archived = [flatten(r, is_deleted=True, loaded_at=loaded_at)
                for r in hubspot.list_archived(since_ms=watermark)]
    deleted = load_rows(bq, archived)
    return {"watermark_ms": watermark, "upserted": total, "archived": deleted}


def main(request=None):
    """Cloud Function HTTP entry point (gcloud functions deploy ... --entry-point main)."""
    from google.cloud import bigquery

    result = sync_contacts(bigquery.Client(), HubSpotClient(os.environ["HUBSPOT_TOKEN"]))
    print(result)  # goes to Cloud Logging
    return result, 200
