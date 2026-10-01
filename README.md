# memberspot_analytics: dbt + BigQuery practice project

A small analytics-engineering project built around the stack Memberspot lists: **HubSpot CRM → BigQuery → dbt → Looker Studio**. It turns raw CRM, billing and product-event data into a single source of truth plus marketing, product and finance marts.

All data is synthetic (`scripts/generate_seed_data.py`). It is deliberately a bit messy, with duplicate CRM records, deleted contacts, messy emails and late-arriving events, because handling that mess is the job.

---

## 1. Run it locally (no GCP account needed)

```bash
pip install -r requirements.txt
./run_all.sh            # seed -> build (14 models + 52 tests) -> snapshot -> docs
dbt docs serve          # opens the lineage graph + documentation in your browser
```

The `dev` target is a local DuckDB file. To explore the results:

```bash
python -c "import duckdb; print(duckdb.connect('memberspot.duckdb').sql('select * from marts.fct_mrr_monthly order by 1 desc limit 6'))"
```

## 2. Run it on BigQuery

1. Create a GCP project and enable the BigQuery API. The free sandbox is enough.
2. Run `gcloud auth application-default login`.
3. Run `export GCP_PROJECT=your-project-id`.
4. Run `./run_all.sh prod`.

This creates the datasets `raw`, `staging`, `intermediate`, `marts` and `snapshots` in the EU location. The project is written with dbt's cross-database macros (`dbt.date_trunc`, `dbt.datediff`, `dbt.dateadd`, `dbt.date_spine`, `dbt.type_*`), so the same SQL compiles for DuckDB and BigQuery.

> The DuckDB target was fully run and tested. The BigQuery target parses and validates, but it hasn't been run against a live BigQuery project. If something fails there, the error will be a small dialect detail. Fixing it is good practice.

## 3. Structure

```
seeds/                      raw data (stands in for what the loader writes to `raw`)
extract/main.py             HubSpot -> BigQuery Cloud Function (incremental loader) + tests
models/
  staging/                  1:1 with sources: rename, cast, clean, dedup. Views.
    _sources.yml            sources + freshness checks
  intermediate/             joins + business logic, reused by marts
    int_contacts__funnel        contact + funnel flags + deals + subscriptions
    int_subscriptions__monthly  subscriptions x month calendar (MRR movements)
    int_months                  month calendar (ephemeral)
  marts/                    what dashboards read. Tables.
    marketing/  dim_contacts (single source of truth), fct_deals, mart_channel_funnel_monthly
    product/    fct_product_events (incremental), fct_daily_active_users, mart_cohort_retention
    finance/    fct_mrr_monthly (MRR bridge, ARR, logo churn)
snapshots/                  SCD2 history of contacts (lifecycle stage over time)
macros/                     schema naming, channel mapping, custom generic tests
tests/                      singular tests (business rules)
analyses/                   SQL interview practice queries on these models
```

### Lineage

```
hubspot.contacts ─► stg_hubspot__contacts ─┬─► int_contacts__funnel ─► dim_contacts ─┬─► fct_deals
hubspot.deals ────► stg_hubspot__deals ────┤                     └─► mart_channel_funnel_monthly
billing.subs ─────► stg_billing__subs ─────┴─► int_subscriptions__monthly ─► fct_mrr_monthly
product.events ───► stg_product__events ──────► fct_product_events ─► fct_daily_active_users
                                                                   └─► mart_cohort_retention
```

## 4. Techniques to talk about in the interview

| Technique | Where | What to say |
|---|---|---|
| **Layering** | staging → intermediate → marts | Staging only cleans. Business logic lives in one place. Marts are shaped for dashboards. |
| **Dedup** | `stg_hubspot__contacts` | The loader appends every changed version. `QUALIFY ROW_NUMBER() OVER (PARTITION BY contact_id ORDER BY updated_at DESC) = 1` keeps the latest. That makes the load idempotent. |
| **Incremental model** | `fct_product_events` | Only re-processes the last N days (`event_lookback_days`) to catch late events. `unique_key` + `merge` prevents duplicates. `--full-refresh` rebuilds everything. |
| **Partitioning / clustering** | `fct_product_events` config | On BigQuery the table is partitioned by `event_date` and clustered by `user_id, event_name`. Dashboards filtered by date scan less data, which means lower cost and faster loads. |
| **Single source of truth** | `dim_contacts` | Every team reads contacts from this one table. Channel definitions live in one macro (`channel_from_hubspot_source`). |
| **Tests** | `_staging.yml`, `_marts.yml`, `tests/` | Generic tests (`unique`, `not_null`, `accepted_values`, `relationships`), custom ones (`non_negative`, `not_in_future`, `unique_combination` for grain) and business-rule tests. |
| **Reconciliation test** | `assert_mrr_bridge_reconciles` | Opening + new − churned = closing MRR, every month. If a number is wrong, the test fails before anyone sees it in Looker Studio. |
| **Cross-team consistency** | `assert_paying_customers_match_dim` | Finance's paying-customer count must equal the CRM's. This is how you keep trust in the numbers. |
| **Snapshots (SCD2)** | `contacts_snapshot` | HubSpot shows only the *current* lifecycle stage. The snapshot keeps history, so you can answer "when did this lead become an MQL?" |
| **Source freshness** | `_sources.yml` | `dbt source freshness` warns if HubSpot data is more than 24h old. That catches a broken loader. |
| **Date spine** | `int_months` | Turns start/end dates into a monthly time series. Months with no activity still show up. |
| **Portability** | `dbt.*` macros, `target.type` checks | The same code runs on DuckDB (dev) and BigQuery (prod). |

## 5. The HubSpot → BigQuery pipeline (`extract/main.py`)

This is the answer to "how would you get HubSpot data into BigQuery?":

1. **Watermark:** read `max(lastmodifieddate)` from the raw table.
2. **Extract:** call the HubSpot Search API with `lastmodifieddate >= watermark`, sorted ascending and paged 100 at a time.
   - Search returns at most 10k results per query, so the loader restarts from the last timestamp it saw.
   - It retries with backoff on 429 (rate limit) and 5xx errors.
3. **Deleted contacts:** Search doesn't return them, so they're fetched separately with `archived=true`. They're appended with `is_deleted = true` and the archive time as the modified date, so they win the dedup.
4. **Load:** append-only, using `WRITE_APPEND`. There are no UPDATEs in raw, which gives full history and safe re-runs.
5. **Transform:** dbt deduplicates in staging.
6. **Schedule:** deploy as a Cloud Function, triggered hourly by Cloud Scheduler. Keep the token in Secret Manager.

```bash
cd extract && python -m pytest -q      # 4 tests, HubSpot + BigQuery faked
```

This is the same pattern as your Kafka → Freshsales work at Elvinci: idempotent loads, an append-only log and dedup downstream. Lead with that link.

## 6. Looker Studio

Connect Looker Studio to the **marts** dataset only, never to raw or staging:
- **Marketing page:** `mart_channel_funnel_monthly` (conversion by channel, won revenue)
- **Product page:** `fct_daily_active_users`, `mart_cohort_retention` (pivot `cohort_month` × `months_since_start`)
- **Finance page:** `fct_mrr_monthly` (MRR bridge, ARR, churn)

The marts are pre-aggregated, so a dashboard reads a few hundred rows instead of scanning the events table. That's the answer to "the dashboard is slow, what do you do?"

## 7. Things to notice (good discussion points)

- **Month-0 retention is below month 1.** A customer who starts on the 30th often has no events that month. Better options are to define the cohort by the first *active* month, or to use 30-day windows instead of calendar months.
- **The funnel uses the current lifecycle stage.** "Reached MQL" is approximated as "current stage ≥ MQL". In production you'd use HubSpot's `hs_lifecyclestage_*_date` properties or the snapshot.
- **Paid Social converts poorly** (~3% vs ~39% for referrals) in this data. That's the kind of insight marketing wants from this mart.

## 8. Practice exercises

1. Add a `stg_hubspot__companies` model and a `dim_companies` mart.
2. Add `mrr_expansion` (plan upgrades) to the MRR bridge.
3. Rewrite `mart_cohort_retention` using the "first active month" cohort definition.
4. Add a test that fails if more than 5% of contacts have no channel.
5. Run `dbt build --target prod` on BigQuery and compare the bytes processed with and without the date filter on `fct_product_events`.
6. Work through `analyses/sql_interview_practice.sql` without looking: dedup, running totals, LAG, rolling averages, ranking and gaps.
