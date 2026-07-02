#!/usr/bin/env python3
"""Poll a URL until it returns 200, print the elapsed milliseconds (or -1 on timeout).

Usage: wait-ready.py <url> <timeout_seconds>
"""
import sys
import time
import urllib.request

url, timeout = sys.argv[1], float(sys.argv[2])
start = time.perf_counter()
while time.perf_counter() - start < timeout:
    try:
        with urllib.request.urlopen(url, timeout=2) as r:
            if r.status == 200:
                print(round((time.perf_counter() - start) * 1000))
                sys.exit(0)
    except Exception:
        pass
    time.sleep(0.1)
print("-1")
sys.exit(1)
