# One endpoint, two cache settings

Does the response cache change the customer data your API returns? This example
checks the same endpoint with caching off and on. It also checks two tenants,
invalid keys, and an attempt to override the tenant in the URL.

## What we observed

On 29 October 2026, the checker below passed against Offloader 0.1.12 using the
bundled 36-row dataset. All **400 checked requests** returned the expected two
Acme account rows. The 200 uncached requests reported `cache: off`. The 200 warmed
requests with the snapshot response cache reported `cache: hit`.

The Acme and Globex demo keys each returned their own account totals, calculated
independently from the CSV. Adding another tenant to the URL returned HTTP 422.
Invalid and revoked keys returned HTTP 401.

The snapshot is deliberately old. Successful responses marked it `stale: true`
and kept serving it. Your application decides whether that age is acceptable.
Turning on the response cache does not make the snapshot fresher.

This was a small synthetic test with client and server on the same laptop. It
checks data and error handling, not production capacity, latency or savings.
The `data` rows matched; request IDs and other response metadata can differ.
Both disposable containers were stopped after the checks.

[Download the results and exact image identifiers](https://offloader.dryga.com/examples/cache-check-results.json).
The fixture came from source revision `8d0794741826e00d8efaf9f333d3b71a08ac9c7a`.

## Repeat the checks

You need Docker, Git, Python 3, curl and OpenSSL. Start from a clone of this repository. The
[quickstart](quickstart.md) explains the fixture and image build. Use the **same
image ID** for both runs so a moving image tag cannot change half the comparison.
Record your image ID, source revision and results alongside your run.

Pull the tested image, then make two temporary copies of the bundled project:

```sh
docker pull ghcr.io/andrewdryga/offloader@sha256:d8bebb86b6de6bab853c88e28847043cc253e9a5807b5f4c76e5c572ce27254f
git rev-parse HEAD
docker image inspect ghcr.io/andrewdryga/offloader@sha256:d8bebb86b6de6bab853c88e28847043cc253e9a5807b5f4c76e5c572ce27254f --format '{{.Id}}'
export CACHE_CHECK_IMAGE=$(docker image inspect ghcr.io/andrewdryga/offloader@sha256:d8bebb86b6de6bab853c88e28847043cc253e9a5807b5f4c76e5c572ce27254f --format '{{.Id}}')
export CACHE_CHECK_DIR=$(mktemp -d)
cp -R examples/customer-analytics "$CACHE_CHECK_DIR/none"
cp -R examples/customer-analytics "$CACHE_CHECK_DIR/snapshot"
python3 - <<'PYCODE'
import os, pathlib, re
for policy in ('none', 'snapshot'):
    p = pathlib.Path(os.environ['CACHE_CHECK_DIR']) / policy / 'endpoints/customer_usage_summary.yml'
    text, count = re.subn(r'policy: snapshot', 'policy: ' + policy, p.read_text())
    if count != 1:
        raise SystemExit('Expected the bundled snapshot response-cache setting')
    p.write_text(text)
PYCODE
```

Start the uncached copy. Both ports bind to loopback. Leave this terminal running:

```sh
docker run --rm \
  -e OFFLOADER_CONFIG=/etc/offloader/offloader.yml \
  -e OFFLOADER_SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e OFFLOADER_ADMIN_TOKEN="$(openssl rand -base64 24)" \
  -e OFFLOADER_DUCKDB_THREADS=2 -e OFFLOADER_POOL_SIZE=4 \
  -p 127.0.0.1:4000:4000 -p 127.0.0.1:4001:4001 \
  -v "$CACHE_CHECK_DIR/none:/etc/offloader:ro" \
  "$CACHE_CHECK_IMAGE"
```

In another terminal, wait for readiness, then run the checker from the repo root:

```sh
curl -fsS http://127.0.0.1:4001/ready
python3 dev/scripts/check-customer-cache.py --base-url http://127.0.0.1:4000 --policy none
```

Stop that container with Ctrl-C. In its original terminal, repeat the same Docker
command with `"$CACHE_CHECK_DIR/snapshot:/etc/offloader:ro"` as the project mount.
Each container starts with a separate writable cache. After it is ready, run:

```sh
python3 dev/scripts/check-customer-cache.py --base-url http://127.0.0.1:4000 --policy snapshot
```

The [Python checker](../dev/scripts/check-customer-cache.py) warms the endpoint, calculates expected rows from the bundled CSV,
checks both tenants and the three rejection cases, then verifies every response
in two 100-request batches at concurrency 1 and 10. A mismatch exits with an error;
only a complete pass prints `"status": "passed"`. It never starts or stops your
server and only accepts an HTTP loopback address. Use these public demo keys only
with the synthetic fixture.

Stop the second container when finished. The temporary project copies can then
be removed. No warehouse or cloud account is involved.

For a useful pilot, repeat on representative data over a longer period. Measure
load time, memory, freshness and expected peak traffic as described in
[Benchmarks](benchmarks.md). To compare serving approaches, see
[Choose a serving path](warehouse-cache-or-snapshot.md).
