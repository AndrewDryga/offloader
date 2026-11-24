"""Replay the same customer dashboard requests against three local serving paths."""
import csv
import hashlib
import json
import math
import platform
import secrets
import shutil
import sqlite3
import statistics
import subprocess
import tempfile
import time
from collections import Counter
from contextlib import contextmanager, closing
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "examples/customer-analytics"
IMAGE = "ghcr.io/andrewdryga/offloader@sha256:d8bebb86b6de6bab853c88e28847043cc253e9a5807b5f4c76e5c572ce27254f"
DAYS = ("2026-05-30", "2026-05-31", "2026-06-01")
SQL = """
SELECT account_id, SUM(active_users) AS active_users_total, SUM(api_calls) AS api_calls_total,
       AVG(storage_gb) AS storage_gb_avg
FROM usage WHERE tenant_id = ? AND usage_date BETWEEN ? AND ?
GROUP BY account_id ORDER BY api_calls_total DESC
"""


def requests():
    full_range = (DAYS[0], DAYS[-1])
    ranges = [full_range] * 20
    ranges.extend((a, b) for a in DAYS for b in DAYS if a <= b and (a, b) != full_range)
    return [(tenant, a, b) for a, b in ranges for tenant in ("acme", "globex")]


def load_source(db):
    db.execute("""CREATE TABLE usage (usage_date TEXT, tenant_id TEXT, account_id TEXT,
        product_area TEXT, active_users INTEGER, api_calls INTEGER, storage_gb REAL, plan TEXT)""")
    with (FIXTURE / "data/customer_usage/customer_usage.csv").open(newline="") as file:
        rows = csv.reader(file)
        next(rows)
        db.executemany("INSERT INTO usage VALUES (?,?,?,?,?,?,?,?)", rows)


def export(db, project, revision, watermark):
    directory = project / "data/customer_usage"
    path = directory / "customer_usage.csv"
    query = db.execute("/* export */ SELECT * FROM usage ORDER BY usage_date, tenant_id, account_id, product_area")
    with path.open("w", newline="") as file:
        writer = csv.writer(file)
        writer.writerow([col[0] for col in query.description])
        rows = query.fetchall()
        writer.writerows(rows)
    size = path.stat().st_size
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest.update(snapshot_id=revision, upstream_run_id=revision, created_at=watermark,
                    watermark=watermark, size_bytes=size, row_count=len(rows))
    manifest["files"][0].update(size_bytes=size, row_count=len(rows))
    manifest_path.write_text(json.dumps(manifest))
    return size


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


@contextmanager
def server(project):
    container = docker("run", "-d", "--rm", "-p", "127.0.0.1::4000", "-p", "127.0.0.1::4001",
                       "-v", f"{project}:/etc/offloader:ro",
                       "-e", "OFFLOADER_CONFIG=/etc/offloader/offloader.yml",
                       "-e", f"OFFLOADER_SECRET_KEY_BASE={secrets.token_hex(48)}",
                       "-e", "OFFLOADER_POOL_SIZE=2", "-e", "OFFLOADER_DUCKDB_THREADS=2", IMAGE)
    try:
        api = "http://" + docker("port", container, "4000/tcp")
        admin = "http://" + docker("port", container, "4001/tcp")
        deadline = time.monotonic() + 60
        while True:
            try:
                with urlopen(admin + "/ready", timeout=2):
                    break
            except OSError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Offloader did not become ready within 60 seconds")
                time.sleep(0.25)
        yield api
    finally:
        docker("stop", "-t", "3", container)


def verify_rows(actual, expected):
    if not expected or len(actual) != len(expected):
        raise ValueError("Wrong number of accounts")
    for row, want in zip(actual, expected):
        if row.keys() != want.keys():
            raise ValueError("Wrong response fields")
        for field, value in want.items():
            matches = math.isclose(row[field], value) if field == "storage_gb_avg" else row[field] == value
            if not matches:
                raise ValueError(f"Unexpected {field} for {want['account_id']}")


def replay(db, api, revision, watermark):
    cache = {}
    observations = []
    for key in requests():
        tenant, start, end = key
        params = ("tenant_" + tenant, start, end)
        direct = [dict(row) for row in db.execute("/* direct */ " + SQL, params)]
        hit = key in cache
        if not hit:
            cache[key] = [dict(row) for row in db.execute("/* cache */ " + SQL, params)]
        verify_rows(cache[key], direct)
        url = f"{api}/v1/endpoints/customer_usage_summary?from={start}&to={end}"
        request = Request(url, headers={"Authorization": "Bearer offl_demo_" + tenant + "_key"})
        before = time.perf_counter()
        with urlopen(request, timeout=10) as response:
            payload = response.read()
        elapsed = (time.perf_counter() - before) * 1000
        body = json.loads(payload)
        meta = body["meta"]
        fresh = meta["freshness"]
        if (meta["snapshot_id"] != revision or fresh["watermark"] != watermark
                or fresh["stale"] is not False or meta["cache"] != "off"):
            raise ValueError("Wrong snapshot, freshness or cache policy")
        verify_rows(body["data"], direct)
        observations.append(dict(tenant=tenant, start=start, end=end, response_cache_hit=hit,
                                 accounts=len(direct), api_calls=sum(row["api_calls_total"] for row in direct),
                                 snapshot_http_ms=round(elapsed, 3)))
    return observations


def main():
    versions = []
    with tempfile.TemporaryDirectory() as tmp, closing(sqlite3.connect(":memory:")) as db:
        db.row_factory = sqlite3.Row
        project = Path(tmp) / "project"
        shutil.copytree(FIXTURE, project)
        contract = project / "endpoints/customer_usage_summary.yml"
        source = contract.read_text()
        if source.count("policy: snapshot") != 1:
            raise ValueError("Expected bundled endpoint cache policy")
        contract.write_text(source.replace("policy: snapshot", "policy: none"))
        load_source(db)
        counts = Counter()

        def count_query(statement):
            for name in ("direct", "cache", "export"):
                if statement.startswith(f"/* {name} */"):
                    counts[name] += 1

        db.set_trace_callback(count_query)
        for version in (1, 2):
            counts.clear()
            revision = f"dashboard-v{version}"
            if version == 2:
                changed = db.execute("""UPDATE usage SET api_calls = api_calls + 1000 WHERE
                    tenant_id = 'tenant_acme' AND account_id = 'acct_apollo'
                    AND usage_date = '2026-05-30' AND product_area = 'api'""")
                if changed.rowcount != 1:
                    raise ValueError("Expected exactly one updated source row")
            watermark = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            size = export(db, project, revision, watermark)
            with server(project) as api:
                records = replay(db, api, revision, watermark)
            times = sorted(record["snapshot_http_ms"] for record in records)
            versions.append(dict(revision=revision, watermark=watermark, direct_queries=counts["direct"],
                                 cache_miss_queries=counts["cache"],
                                 export_queries=counts["export"], export_bytes=size,
                                 snapshot_http_p50_ms=statistics.median(times),
                                 snapshot_http_p95_ms=times[math.ceil(.95 * len(times)) - 1],
                                 requests=records))
    first, second = (v["requests"] for v in versions)
    if second[0]["api_calls"] - first[0]["api_calls"] != 1000 or second[1]["api_calls"] != first[1]["api_calls"]:
        raise ValueError("Unexpected change in tenant totals between versions")
    fixture_file = FIXTURE / "data/customer_usage/customer_usage.csv"
    print(json.dumps(dict(image=IMAGE, fixture_source=str(fixture_file.relative_to(ROOT)),
                          fixture_sha256=hashlib.sha256(fixture_file.read_bytes()).hexdigest(),
                          python=platform.python_version(), sqlite=sqlite3.sqlite_version,
                          platform=f"{platform.system()} {platform.machine()}", versions=versions), indent=2))


if __name__ == "__main__":
    main()
