# Production image for the Offloader server. Multi-stage: build a self-contained
# release (bundled ERTS) in the Elixir image, then run it on a slim Debian with only
# the C libraries the DuckDB NIF and crypto need. Config and secrets are NEVER baked
# in — the container reads them from env vars + a mounted config at runtime.
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.1-erlang-29.0.1-debian-bookworm-20260610-slim
ARG RUNTIME_IMAGE=debian:bookworm-slim

# ── builder ──────────────────────────────────────────────────────────────────────
FROM ${ELIXIR_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

# Fetch + compile deps first for layer caching (the DuckDB NIF is downloaded here).
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
RUN mix compile
RUN mix release

# ── runtime ──────────────────────────────────────────────────────────────────────
FROM ${RUNTIME_IMAGE} AS runtime

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
     libstdc++6 openssl libncurses6 ca-certificates locales curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# Run as a non-root user; cache lives in a mounted path it owns.
RUN useradd --create-home --uid 10001 offloader \
  && mkdir -p /var/lib/offloader/cache \
  && chown -R offloader:offloader /var/lib/offloader

WORKDIR /app
COPY --from=builder --chown=offloader:offloader /app/_build/prod/rel/offloader ./
USER offloader

ENV OFFLOADER_CACHE_DIR=/var/lib/offloader/cache \
    OFFLOADER_API_PORT=4000 \
    OFFLOADER_ADMIN_PORT=4001 \
    PHX_SERVER=true

# API port for product traffic; admin port for health/metrics/diagnostics/docs.
EXPOSE 4000 4001
VOLUME ["/var/lib/offloader/cache"]

# Liveness against the admin port (always up while the process runs).
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${OFFLOADER_ADMIN_PORT}/live" || exit 1

ENTRYPOINT ["/app/bin/offloader"]
CMD ["start"]
