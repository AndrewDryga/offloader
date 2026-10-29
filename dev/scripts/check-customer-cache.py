#!/usr/bin/env python3
"""Check the bundled customer-analytics fixture on a local running Offloader."""
import argparse
import concurrent.futures
import csv
import json
import math
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

QUERY = "/v1/endpoints/customer_usage_summary?from=2026-05-30&to=2026-06-01"


def expected_rows(path, tenant):
    grouped = {}
    with path.open() as source:
        for row in csv.DictReader(source):
            if row["tenant_id"] != tenant or not "2026-05-30" <= row["usage_date"] <= "2026-06-01":
                continue
            target = grouped.setdefault(row["account_id"], {"account_id": row["account_id"], "active_users_total": 0, "api_calls_total": 0, "storage": []})
            target["active_users_total"] += int(row["active_users"])
            target["api_calls_total"] += int(row["api_calls"])
            target["storage"].append(float(row["storage_gb"]))
    return sorted([dict(account_id=v["account_id"], active_users_total=v["active_users_total"], api_calls_total=v["api_calls_total"], storage_gb_avg=sum(v["storage"]) / len(v["storage"])) for v in grouped.values()], key=lambda v: -v["api_calls_total"])


def check(base, policy, fixture):
    def request(token, suffix=""):
        req = Request(base + QUERY + suffix, headers={"Authorization": "Bearer " + token})
        try:
            with urlopen(req, timeout=10) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            return error.code, json.load(error)

    def require(condition, message):
        if not condition:
            raise ValueError(message)

    expected = {name: expected_rows(fixture, "tenant_" + name) for name in ("acme", "globex")}

    def validate(result, tenant):
        status, body = result
        require(status == 200, f"{tenant}: expected HTTP 200, got {status}")
        rows = body["data"]
        require(len(rows) == len(expected[tenant]) > 0, f"{tenant}: wrong or empty row count")
        for got, want in zip(rows, expected[tenant]):
            require(got.keys() == want.keys(), f"{tenant}: unexpected fields")
            for key, value in want.items():
                equal = math.isclose(got[key], value, rel_tol=1e-10, abs_tol=1e-10) if isinstance(value, float) else got[key] == value
                require(equal, f"{tenant}: wrong {key}")
        require(body["meta"]["freshness"]["stale"] is True, "Bundled old snapshot must be marked stale")
        return body["meta"]["cache"]

    # Warm the Acme response, then check that Globex gets its own data.
    validate(request("offl_demo_acme_key"), "acme")
    validate(request("offl_demo_globex_key"), "globex")
    for token, suffix, status in [("offl_demo_acme_key", "&tenant_id=tenant_globex", 422), ("invalid-demo-key", "", 401), ("offl_demo_revoked_key", "", 401)]:
        require(request(token, suffix)[0] == status, f"Expected rejection HTTP {status}")
    wanted_cache = "off" if policy == "none" else "hit"
    results = []
    for concurrency in (1, 10):
        def one(_):
            cache = validate(request("offl_demo_acme_key"), "acme")
            require(cache == wanted_cache, f"Expected cache {wanted_cache}, got {cache}")
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
            list(pool.map(one, range(100)))
        results.append({"concurrency": concurrency, "checked_requests": 100, "cache": wanted_cache})
    return {"policy": policy, "status": "passed", "rows_per_response": len(expected["acme"]), "tenant_checks": ["acme", "globex"], "tenant_override_status": 422, "invalid_and_revoked_key_status": 401, "stale": True, "runs": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True, help="Already-running local API, e.g. http://127.0.0.1:4000")
    parser.add_argument("--policy", required=True, choices=("none", "snapshot"))
    args = parser.parse_args()
    url = urlsplit(args.base_url)
    if url.scheme != "http" or url.hostname not in ("127.0.0.1", "localhost", "::1") or url.path not in ("", "/") or url.query or url.fragment or url.username or url.password:
        parser.error("Use an http loopback origin without credentials, path, query or fragment")
    fixture = Path(__file__).resolve().parents[2] / "examples/customer-analytics/data/customer_usage/customer_usage.csv"
    try:
        result = check(args.base_url.rstrip("/"), args.policy, fixture)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"cache check failed: {error}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
