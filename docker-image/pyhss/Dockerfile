# =============================================================================
# PyHSS (IMS HSS, Python) — built from upstream source on an Alpine base.
#
# Upstream: https://github.com/nickvsnetworking/pyhss
# Pinned to tag 1.0.2 (latest release, 2024-07-03). PyHSS has only ever cut
# 1.0.0 / 1.0.1 / 1.0.2; everything past that lives on `master`. Override with
# --build-arg PYHSS_VERSION=master if you want the bleeding edge.
#
# Base choice — Alpine (the deploy's rule: 能alpine就alpine):
#   The requirements.txt has three C-extensions. None is a hard blocker on musl:
#     * aiohttp==3.8.5  -> ships a prebuilt cp311 musllinux wheel (installs as-is)
#     * pysctp==0.7.2   -> no musl wheel, but compiles from sdist against
#                          lksctp-tools-dev (SCTP headers)
#     * mysqlclient     -> no Linux wheel anywhere, compiles from sdist against
#                          mariadb-dev (mariadb_config + connector headers)
#     * pycryptodome    -> ships musl wheels
#   So Alpine is fully viable. There is ONE hard constraint, but it is on the
#   PYTHON VERSION, not on the distro: aiohttp 3.8.5 has wheels (manylinux AND
#   musllinux) only up to cp311 and does NOT build on Python 3.12+ (it uses
#   private CPython C-API removed in 3.12). pysctp 0.7.2 likewise tops out at a
#   cp311 wheel. => we MUST stay on Python 3.11. python:3.11-alpine (Alpine 3.21)
#   gives us exactly that, plus a prebuilt musl aiohttp wheel.
#
# Build:  docker build -t open5gs_pyhss docker-image/pyhss
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: builder — compile the C-extension deps into wheels.
# Doing this in a throwaway stage keeps gcc / *-dev headers out of the runtime
# image; only the finished wheels are copied forward.
# -----------------------------------------------------------------------------
FROM python:3.11-alpine AS builder

ARG PYHSS_VERSION=1.0.2

# Toolchain + headers needed to compile the from-source deps:
#   build-base/gcc/musl-dev/python3-dev -> any C-extension
#   mariadb-dev (+ pkgconf)             -> mysqlclient (provides mariadb_config)
#   lksctp-tools-dev                    -> pysctp (sctp.h)
#   libffi-dev / openssl-dev            -> safety net for crypto/cffi sdists
RUN apk add --no-cache \
        git \
        build-base \
        python3-dev \
        musl-dev \
        gcc \
        pkgconf \
        mariadb-dev \
        lksctp-tools-dev \
        libffi-dev \
        openssl-dev

# Clone the exact source we ship at runtime, and build a wheelhouse from its
# requirements. --prefer-binary lets pip grab the musl aiohttp/pycryptodome
# wheels and only compile what truly has no wheel (mysqlclient, pysctp).
WORKDIR /src
RUN git clone https://github.com/nickvsnetworking/pyhss . && \
    git checkout "${PYHSS_VERSION}"

# requirements.txt hard-pins PyYAML==6.0, whose sdist fails to build with Cython 3
# ("'build_ext' object has no attribute 'cython_sources'") and has no musl cp311 wheel.
# 6.0.1 is a drop-in patch with a musl wheel. We EDIT the requirement directly — a pip
# `-c` constraint can't override a hard `==` pin (yields ResolutionImpossible).
RUN sed -i 's/^PyYAML==6.0$/PyYAML==6.0.1/' requirements.txt

RUN pip install --upgrade pip wheel && \
    pip wheel --wheel-dir=/wheels --prefer-binary -r requirements.txt

# -----------------------------------------------------------------------------
# Stage 2: runtime — Alpine python + only the runtime shared libs and the
# PyHSS source. The per-deployment config + init script are MOUNTED at runtime
# (compose mounts ./pyhss:/mnt/pyhss and runs /mnt/pyhss/pyhss_init.sh), exactly
# like the original ubuntu:jammy image — so the deployment works unchanged.
# -----------------------------------------------------------------------------
FROM python:3.11-alpine

ARG PYHSS_VERSION=1.0.2

# Runtime-only packages (no -dev, no compiler):
#   bash                 -> pyhss_init.sh has a #!/bin/bash shebang + [[ ]] tests
#   mariadb-client       -> init uses `mysqladmin ping` and `mysql` (DB bootstrap)
#   mariadb-connector-c  -> shared lib mysqlclient links against at runtime
#   lksctp-tools         -> libsctp.so for the compiled pysctp
#   redis                -> init runs `redis-server --daemonize yes`
RUN apk add --no-cache \
        bash \
        mariadb-client \
        mariadb-connector-c \
        lksctp-tools \
        redis \
        tzdata

# Install the prebuilt wheelhouse — no network, no compiler in this stage.
COPY --from=builder /wheels /wheels
COPY --from=builder /src/requirements.txt /tmp/requirements.txt
RUN pip install --no-index --find-links=/wheels -r /tmp/requirements.txt && \
    rm -rf /wheels /tmp/requirements.txt /root/.cache

# Ship the PyHSS source at the same path the original image used (/pyhss), so
# the mounted pyhss_init.sh (which `cd services` and runs the *Service.py files)
# works without modification.
WORKDIR /pyhss
# Reuse the source the builder already cloned+checked-out (no git needed at runtime,
# guaranteed same version as the wheelhouse).
COPY --from=builder /src /pyhss
RUN rm -rf /pyhss/.git && mkdir -p /pyhss/log/

# Match the original image's launch model: CMD is the mounted init script, which
# bootstraps the DB user, renders config.yaml, starts redis, then launches the
# API / diameter / hss services. The image stays generic (config mounted, not baked).
CMD ["/mnt/pyhss/pyhss_init.sh"]
