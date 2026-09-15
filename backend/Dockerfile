# syntax=docker/dockerfile:1.7
#
# Kioku backend image — shared by the `migrate`, `api` and `worker` services.
#
# Two stages are mandatory, not stylistic: ruby:3.4.10-slim-trixie ships no
# compiler, so `bundle install` of native gems (pg, bigdecimal, json) fails there.
# The full ruby:3.4.10-trixie image builds the gems; the slim image runs them.
#
# The runtime needs postgresql-client-18 because schema_format = :sql makes
# `rails db:schema:dump` shell out to pg_dump, and pg_dump's major version must
# match the server (PostgreSQL 18.6 in paradedb/paradedb:0.25.9-pg18). Stock
# Debian trixie only carries PostgreSQL 17, so the PGDG repository is added and
# pinned to the exact same build the server uses: 18.6-1.pgdg13+2.

ARG RUBY_VERSION=3.4.10
ARG BUILDER_IMAGE=ruby:${RUBY_VERSION}-trixie
ARG RUNTIME_IMAGE=ruby:${RUBY_VERSION}-slim-trixie

# Debian 13 codename. Hardcoded rather than read from /etc/os-release so the
# apt source cannot silently follow a base-image bump.
ARG DEBIAN_CODENAME=trixie

# Exact PostgreSQL client/library build. Verified identical to the server's:
#   postgres (PostgreSQL) 18.6 (Debian 18.6-1.pgdg13+2)
ARG PG_MAJOR=18
ARG PG_PKG_VERSION=18.6-1.pgdg13+2

# PGDG signing key ACCC4CF8. Verified fingerprint — the build fails if the key
# served at that URL is ever a different key.
ARG PGDG_KEY_URL=https://www.postgresql.org/media/keys/ACCC4CF8.asc
ARG PGDG_KEY_FINGERPRINT=B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8

ARG APP_UID=1000
ARG APP_GID=1000
ARG APP_ROOT=/rails

# By default every bundle group is installed, so the one image can run the app,
# the Minitest suite against PostgreSQL, and RuboCop. For a slimmer production
# image build with --build-arg BUNDLE_WITHOUT=development:test, and set
# RAILS_ENV=production (which also requires SECRET_KEY_BASE at boot).
ARG BUNDLE_WITHOUT=""


# =============================================================================
# Stage: pgdg — fetch and verify the PGDG signing key once, share it downstream.
# Both the builder and the runtime need the identical trusted key and apt source.
# =============================================================================
FROM ${RUNTIME_IMAGE} AS pgdg

ARG DEBIAN_CODENAME
ARG PGDG_KEY_URL
ARG PGDG_KEY_FINGERPRINT

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL "${PGDG_KEY_URL}" -o /tmp/pgdg.asc; \
    gpg --show-keys --with-colons /tmp/pgdg.asc | grep -q ":${PGDG_KEY_FINGERPRINT}:"; \
    gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg /tmp/pgdg.asc; \
    chmod 0644 /etc/apt/keyrings/pgdg.gpg; \
    printf 'deb [signed-by=/etc/apt/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' \
        "${DEBIAN_CODENAME}" > /etc/apt/sources.list.d/pgdg.list; \
    rm -f /tmp/pgdg.asc


# =============================================================================
# Stage: builder — compile native gems against the same libpq the runtime uses.
# =============================================================================
FROM ${BUILDER_IMAGE} AS builder

ARG PG_PKG_VERSION
ARG APP_ROOT
ARG BUNDLE_WITHOUT

COPY --from=pgdg /etc/apt/keyrings/pgdg.gpg /etc/apt/keyrings/pgdg.gpg
COPY --from=pgdg /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/pgdg.list

# libpq-dev is taken from PGDG at the pinned version so the `pg` gem compiles
# against exactly the libpq the runtime stage installs. Debian's own libpq-dev is
# PostgreSQL 17 and would introduce a build/runtime version skew.
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        git \
        "libpq5=${PG_PKG_VERSION}" \
        "libpq-dev=${PG_PKG_VERSION}"; \
    rm -rf /var/lib/apt/lists/*

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_APP_CONFIG=/usr/local/bundle \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_FROZEN=1 \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3 \
    BUNDLE_WITHOUT=${BUNDLE_WITHOUT}

WORKDIR ${APP_ROOT}

# Gemfile.lock is authoritative: BUNDLE_DEPLOYMENT/BUNDLE_FROZEN make the build
# fail rather than silently resolve a different dependency set.
COPY Gemfile Gemfile.lock ./
RUN set -eux; \
    bundle install; \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git


# =============================================================================
# Stage: runtime — no compiler, no build tooling.
# =============================================================================
FROM ${RUNTIME_IMAGE} AS runtime

ARG PG_MAJOR
ARG PG_PKG_VERSION
ARG APP_UID
ARG APP_GID
ARG APP_ROOT
ARG BUNDLE_WITHOUT

COPY --from=pgdg /etc/apt/keyrings/pgdg.gpg /etc/apt/keyrings/pgdg.gpg
COPY --from=pgdg /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/pgdg.list

# curl is required by the api service's /up healthcheck.
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        tzdata \
        "libpq5=${PG_PKG_VERSION}" \
        "postgresql-client-${PG_MAJOR}=${PG_PKG_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    pg_dump --version

RUN set -eux; \
    groupadd --gid "${APP_GID}" kioku; \
    useradd --uid "${APP_UID}" --gid "${APP_GID}" --create-home --shell /bin/bash kioku; \
    install -d -o kioku -g kioku -m 0750 /var/lib/kioku/objects

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --chown=kioku:kioku . ${APP_ROOT}

# Created after the source copy so they exist and are writable even when the
# repository ships no tmp/ or log/ directory.
RUN install -d -o kioku -g kioku -m 0755 \
        ${APP_ROOT}/tmp ${APP_ROOT}/tmp/pids ${APP_ROOT}/log

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_APP_CONFIG=/usr/local/bundle \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_FROZEN=1 \
    BUNDLE_WITHOUT=${BUNDLE_WITHOUT}

# Container logs must reach `docker compose logs`; a migration or boot failure that
# only lands in log/*.log is an invisible failure. The Rails environment configs
# must honour this in development as well as production.
ENV RAILS_LOG_TO_STDOUT=1

# Default retained-object root. Compose overrides it with KIOKU_OBJECT_ROOT and
# mounts the shared objects_data volume here for both api and worker.
ENV KIOKU_OBJECT_ROOT=/var/lib/kioku/objects

WORKDIR ${APP_ROOT}
USER kioku

EXPOSE 3000

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]
