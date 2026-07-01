#!/usr/bin/env python3
"""Regenerate customer_usage.csv deterministically (no randomness).

The values are derived from stable SHA-256 hashes of the row's keys, so re-running
this always produces the byte-identical file that is checked in. Run from anywhere:

    python3 examples/customer-analytics/data/customer_usage/generate.py

If you change the shape here, update data/customer_usage/manifest.json
(row_count, size_bytes) and the dataset/endpoint contracts to match.
"""
import csv
import hashlib
import os

OUT = os.path.join(os.path.dirname(__file__), "customer_usage.csv")

TENANTS = {
    "tenant_acme": ["acct_apollo", "acct_zephyr"],
    "tenant_globex": ["acct_orion"],
    "tenant_initech": ["acct_vega"],
}
DATES = ["2026-05-30", "2026-05-31", "2026-06-01"]
AREAS = ["dashboards", "api", "exports"]
PLAN = {
    "acct_apollo": "enterprise",
    "acct_zephyr": "growth",
    "acct_orion": "growth",
    "acct_vega": "starter",
}


def h(*parts):
    return int(hashlib.sha256("|".join(parts).encode()).hexdigest(), 16)


def rows():
    out = []
    for d in DATES:
        for tenant, accts in TENANTS.items():
            for a in accts:
                for area in AREAS:
                    active = 5 + h(d, a, area) % 40
                    calls = 100 + h("c", d, a, area) % 9000
                    storage = round(1.0 + (h("s", a, area) % 500) / 10.0, 1)
                    out.append([d, tenant, a, area, active, calls, storage, PLAN[a]])
    out.sort(key=lambda r: (r[0], r[1], r[2], r[3]))
    return out


def main():
    data = rows()
    with open(OUT, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "usage_date",
                "tenant_id",
                "account_id",
                "product_area",
                "active_users",
                "api_calls",
                "storage_gb",
                "plan",
            ]
        )
        w.writerows(data)
    print(f"wrote {len(data)} rows, {os.path.getsize(OUT)} bytes -> {OUT}")


if __name__ == "__main__":
    main()
