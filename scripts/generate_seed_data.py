"""
Generate synthetic raw data that mimics what a HubSpot -> BigQuery loader
and a product event tracker would land in the `raw` dataset.

The data is deliberately a bit messy, the way real raw data is:
  * the CRM sync re-delivers updated contacts, so some contact_ids appear
    more than once (older versions must be deduplicated in staging)
  * some contacts are archived/deleted in HubSpot (is_deleted = true)
  * emails come with mixed case and stray whitespace
  * product events arrive slightly late (loaded_at > event_timestamp)

Run:  python scripts/generate_seed_data.py
Output: seeds/*.csv  (loaded with `dbt seed`)
"""
import csv
import random
from datetime import datetime, timedelta
from pathlib import Path

random.seed(42)
OUT = Path(__file__).resolve().parents[1] / "seeds"
OUT.mkdir(exist_ok=True)

START = datetime(2025, 1, 1)
END = datetime(2026, 9, 15)
N_CONTACTS = 700

SOURCES = [  # HubSpot "original source" values with rough weights
    ("ORGANIC_SEARCH", 0.30),
    ("PAID_SEARCH", 0.20),
    ("PAID_SOCIAL", 0.18),
    ("EMAIL_MARKETING", 0.10),
    ("REFERRALS", 0.12),
    ("DIRECT_TRAFFIC", 0.10),
]
# conversion probability to customer differs by channel -> interesting marts
CONVERSION = {
    "ORGANIC_SEARCH": 0.22, "PAID_SEARCH": 0.18, "PAID_SOCIAL": 0.10,
    "EMAIL_MARKETING": 0.25, "REFERRALS": 0.35, "DIRECT_TRAFFIC": 0.20,
}
CAMPAIGNS = {
    "PAID_SEARCH": ["gads_brand", "gads_online_course_platform", "gads_lms_competitor"],
    "PAID_SOCIAL": ["meta_coaches_q1", "meta_lookalike", "linkedin_b2b_onboarding"],
    "EMAIL_MARKETING": ["newsletter", "webinar_followup"],
}
PLANS = {"basic": 39, "pro": 99, "business": 249}  # EUR per month (synthetic)
FIRST = ["Anna", "Lukas", "Mia", "Jonas", "Lea", "Paul", "Sophie", "Felix", "Emma", "Ben",
         "Laura", "Tim", "Nina", "David", "Sara", "Max", "Julia", "Leon", "Hannah", "Noah"]
COMPANY_SUFFIX = ["Coaching", "Akademie", "Consulting", "Training GmbH", "Academy", "Studio"]
EVENTS = [("login", 0.55), ("lesson_viewed", 0.20), ("course_created", 0.05),
          ("lesson_published", 0.08), ("member_invited", 0.07), ("video_uploaded", 0.05)]


def pick(weighted):
    r, acc = random.random(), 0.0
    for value, w in weighted:
        acc += w
        if r <= acc:
            return value
    return weighted[-1][0]


def rand_dt(a, b):
    return a + timedelta(seconds=random.randint(0, int((b - a).total_seconds())))


def fmt(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S")


contacts, deals, subs, events = [], [], [], []
deal_id = sub_id = event_id = 0

for i in range(1, N_CONTACTS + 1):
    cid = 100000 + i
    source = pick(SOURCES)
    created = rand_dt(START, END - timedelta(days=5))
    name = random.choice(FIRST)
    company = f"{name} {random.choice(COMPANY_SUFFIX)}"
    email = f"{name.lower()}.{cid}@example.com"
    if random.random() < 0.15:  # messy raw emails
        email = f"  {email.upper()} " if random.random() < 0.5 else email.capitalize()
    campaign = random.choice(CAMPAIGNS.get(source, [""]))

    # funnel progression
    is_customer = random.random() < CONVERSION[source]
    if is_customer:
        stage = "customer"
    else:
        stage = random.choices(
            ["subscriber", "lead", "marketingqualifiedlead", "salesqualifiedlead", "opportunity"],
            weights=[25, 35, 20, 12, 8])[0]
    updated = min(END, created + timedelta(days=random.randint(0, 60), hours=3))
    # junk/spam contacts get archived in HubSpot (never paying customers)
    is_deleted = (not is_customer) and random.random() < 0.03

    # ~6%: loader re-delivered an older version of the record
    if random.random() < 0.06:
        contacts.append([cid, email, name, company, "lead", source, campaign,
                         fmt(created), fmt(created + timedelta(hours=2)), "false"])
    contacts.append([cid, email, name, company, stage, source, campaign,
                     fmt(created), fmt(updated), str(is_deleted).lower()])

    # deals
    if stage in ("salesqualifiedlead", "opportunity") or is_customer:
        deal_id += 1
        plan = random.choices(list(PLANS), weights=[45, 40, 15])[0]
        d_created = created + timedelta(days=random.randint(1, 20))
        if is_customer:
            dstage, close = "closedwon", d_created + timedelta(days=random.randint(3, 30))
        elif stage == "opportunity":
            dstage, close = random.choice(["appointmentscheduled", "presentationscheduled",
                                           "decisionmakerboughtin"]), None
        else:
            dstage = "closedlost"
            close = d_created + timedelta(days=random.randint(5, 40))
        if close and close > END:
            close = END
        if d_created > END:
            d_created = END - timedelta(days=1)
        deals.append([900000 + deal_id, cid, dstage, PLANS[plan] * 12, plan,
                      fmt(d_created), fmt(close) if close else "", fmt(close or d_created)])

        # subscriptions + product usage for customers
        if is_customer:
            sub_id += 1
            started = close
            churn_p = {"basic": 0.45, "pro": 0.30, "business": 0.15}[plan]
            cancelled = None
            if random.random() < churn_p:
                cancelled = started + timedelta(days=random.randint(30, 400))
                if cancelled >= END:
                    cancelled = None
            subs.append([f"sub_{sub_id:05d}", cid, plan, PLANS[plan],
                         fmt(started), fmt(cancelled) if cancelled else ""])

            active_until = cancelled or END
            engagement = random.uniform(0.15, 0.7)
            day = started
            while day < active_until:
                days_in = (day - started).days
                p_active = engagement * (0.6 + 0.4 * max(0.0, 1 - days_in / 365))
                if random.random() < p_active:
                    for _ in range(random.randint(1, 4)):
                        event_id += 1
                        ts = day + timedelta(seconds=random.randint(0, 86399))
                        loaded = ts + timedelta(minutes=random.randint(1, 180))
                        events.append([f"evt_{event_id:07d}", cid, pick(EVENTS),
                                       fmt(ts), fmt(loaded)])
                day += timedelta(days=random.choice([1, 1, 2, 3, 7]))

random.shuffle(contacts)


def write(name, header, rows):
    with open(OUT / f"{name}.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    print(f"{name}: {len(rows)} rows")


write("hubspot_contacts",
      ["contact_id", "email", "firstname", "company", "lifecyclestage", "hs_analytics_source",
       "utm_campaign", "createdate", "lastmodifieddate", "is_deleted"], contacts)
write("hubspot_deals",
      ["deal_id", "associated_contact_id", "dealstage", "amount", "plan", "createdate",
       "closedate", "lastmodifieddate"], deals)
write("billing_subscriptions",
      ["subscription_id", "contact_id", "plan", "mrr_eur", "started_at", "cancelled_at"], subs)
write("product_events",
      ["event_id", "user_id", "event_name", "event_timestamp", "loaded_at"], events)
