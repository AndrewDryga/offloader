#!/usr/bin/env python3
"""One benchmark scenario: fire N requests at a concurrency level, report percentiles.

Usage: bench-load.py <base_url> <endpoint> <token> <requests> <concurrency> <vary>
  vary=1  append a unique offset per request (bypasses the response cache -> fresh reads)
  vary=0  identical params every request (exercises the response-cache hit path)

Prints one JSON object to stdout. Stdlib only. Latency is wall time per request in ms.
"""
import concurrent.futures
import json
import sys
import time
import urllib.request

base, endpoint, token, n, conc, vary = (
    sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6] == "1"
)
headers = {"Authorization": f"Bearer {token}"}


def url_for(i):
    u = f"{base}/v1/endpoints/{endpoint}?from=2026-05-30&to=2026-06-01"
    return u + (f"&offset={i}" if vary else "")


def one(i):
    start = time.perf_counter()
    try:
        req = urllib.request.Request(url_for(i), headers=headers)
        with urllib.request.urlopen(req, timeout=30) as r:
            r.read()
            ok = r.status == 200
    except Exception:
        ok = False
    return (time.perf_counter() - start) * 1000.0, ok


def pct(sorted_lat, p):
    if not sorted_lat:
        return None
    k = min(len(sorted_lat) - 1, round(p / 100 * (len(sorted_lat) - 1)))
    return round(sorted_lat[k], 2)


lat, errors = [], 0
t0 = time.perf_counter()
with concurrent.futures.ThreadPoolExecutor(max_workers=conc) as pool:
    for ms, ok in pool.map(one, range(n)):
        if ok:
            lat.append(ms)
        else:
            errors += 1
wall = time.perf_counter() - t0
lat.sort()

print(json.dumps({
    "requests": n,
    "concurrency": conc,
    "errors": errors,
    "p50_ms": pct(lat, 50),
    "p95_ms": pct(lat, 95),
    "p99_ms": pct(lat, 99),
    "max_ms": round(max(lat), 2) if lat else None,
    "rps": round(n / wall, 1) if wall > 0 else None,
}))
