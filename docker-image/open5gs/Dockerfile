# =============================================================================
# open5gs (5G Core + 4G EPC) — built from source at a pinned stable tag.
#
# Replaces the prebuilt `docker_open5gs` base image with our own multi-stage
# build. Same launch model as the original: COMPONENT_NAME selects which NF
# daemon to run, per-component config + init scripts are MOUNTED at runtime
# (compose mounts ./mme:/mnt/mme etc.), CMD stays /open5gs_init.sh — so the
# existing compose files keep working unchanged.
#
# ---------------------------------------------------------------------------
# WHY DEBIAN, NOT ALPINE  (the user's rule is "Alpine unless a hard limit")
# ---------------------------------------------------------------------------
# open5gs ITSELF builds cleanly on Alpine/musl — there is an official Alpine
# guide, and every C/C++ dep is musl-friendly:
#   - lksctp-tools-dev (libsctp), gnutls-dev, libgcrypt-dev, libidn-dev,
#     mongo-c-driver-dev (community), libmicrohttpd-dev, curl-dev, nghttp2-dev,
#     talloc-dev, yaml-dev  → all in Alpine main/community.
#   - libtins (REQUIRED by open5gs-upfd's ARP/ND responder, src/upf/arp-nd.cpp)
#     is NOT in Alpine main/community, but open5gs ships a meson wrap
#     (subprojects/libtins.wrap → open5gs/libtins r4.5) so meson builds it from
#     source automatically. So libtins is NOT a blocker on either base.
#   - freeDiameter (HSS/PCRF) and prometheus-client-c are also meson wraps,
#     built from source — base-agnostic.
#
# The HARD blocker is the MongoDB shell, NOT open5gs:
#   hss/hss_init.sh does `ln -s /usr/bin/mongo /usr/bin/mongosh` and
#   misc/db/open5gs-dbctl shells out to `mongosh --eval ...` to provision
#   subscribers. MongoDB publishes NO musl build of mongosh or the legacy mongo
#   shell; the npm/prebuilt binaries are glibc-only and fail on musl with
#   "libc.so.6: cannot open shared object file". The only Alpine work-arounds
#   (gcompat / sgerrand glibc shim) are explicitly unreliable / not-for-prod.
# Because THIS image must carry a working mongosh for the HSS/UDR/PCF init
# path, we use Debian. If subscriber provisioning ever moves out of this image,
# flip the base to alpine:3.20 and use the apk names listed above.
#
# Build:  docker build -t open5gs_open5gs docker-image/open5gs
# (the compose `image:` is `docker_open5gs`; tag accordingly, or set build:)
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: builder — compile open5gs from source + build the npm WebUI
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS builder

ARG OPEN5GS_VERSION=v2.7.7
ARG NODE_MAJOR=20
ENV DEBIAN_FRONTEND=noninteractive

# Build toolchain + open5gs build deps. These mirror the upstream "Building from
# Sources" guide for Debian/Ubuntu. flex/bison are needed by the freeDiameter
# meson subproject; cmake by the libtins meson subproject; libpcap-dev is what
# the libtins fork links against (arp-nd raw packet send). The mongo-c-driver /
# libbson / yaml / microhttpd / nghttp2 / talloc / idn / gnutls / gcrypt set is
# the open5gs core requirement.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git \
        python3-pip python3-setuptools python3-wheel \
        ninja-build build-essential flex bison cmake meson pkg-config \
        libsctp-dev libgnutls28-dev libgcrypt-dev libssl-dev libidn11-dev \
        libmongoc-dev libbson-dev libyaml-dev \
        libmicrohttpd-dev libcurl4-gnutls-dev libnghttp2-dev \
        libtins-dev libtalloc-dev libpcap-dev \
    && rm -rf /var/lib/apt/lists/*

# Node.js (for `npm ci` of the WebUI). NodeSource repo, same as the old base.
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Clone at the pinned tag WITH submodules. open5gs uses meson "wrap" subprojects
# (freeDiameter, libtins fallback, prometheus-client-c, usrsctp) which meson
# fetches during `meson build` — so a network connection is needed at build time.
# Install prefix is /open5gs/install (same layout the old base + init scripts
# expect: /open5gs/install/{bin,etc,lib,include}).
RUN git clone --recursive --branch ${OPEN5GS_VERSION} --depth 1 \
        https://github.com/open5gs/open5gs.git /open5gs/src && \
    cd /open5gs/src && \
    meson setup build --prefix=/open5gs/install \
        --buildtype=release && \
    ninja -C build && \
    ninja -C build install && \
    mkdir -p /open5gs/install/include

# Build the WebUI (Next.js). `npm ci` matches the old base; the runtime stage
# launches it with `npm run dev` via webui/webui_init.sh.
RUN cd /open5gs/src/webui && npm ci

# Stage the DB tooling (open5gs-dbctl + python helpers) the init scripts use.
RUN cp -a /open5gs/src/misc /open5gs/misc

# Strip symbols from the built binaries + libs — biggest safe size win. Real
# files only (skip .so symlinks); trailing `true` so a non-strippable file
# (e.g. a static .a or script) never fails the build.
RUN find /open5gs/install/bin -type f -exec strip --strip-unneeded {} + 2>/dev/null ; \
    find /open5gs/install/lib -type f \( -name '*.so' -o -name '*.so.*' \) \
        -exec strip --strip-unneeded {} + 2>/dev/null ; \
    true

# -----------------------------------------------------------------------------
# Stage 2: runtime — only the runtime shared libs + install + webui + db tools
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim

ARG NODE_MAJOR=20
ENV DEBIAN_FRONTEND=noninteractive

# Runtime: the non -dev shared libraries matching the build deps, plus the
# tools the launch scripts rely on:
#   - iproute2 + iptables: UPF/SGWU/SMF init create the ogstun device and NAT
#     rules (`ip tuntap`, `iptables -t nat ...`); the per-component init scripts
#     and open5gs_init.sh assume these exist.
#   - iputils-ping / net-tools / tcpdump / traceroute: debugging parity with the
#     old base image.
#   - mongodb-mongosh: the `mongosh` shell that misc/db/open5gs-dbctl calls (and
#     that hss_init.sh symlinks /usr/bin/mongo -> /usr/bin/mongosh). This is the
#     reason this image is Debian and not Alpine (see header). The mongod SERVER
#     itself runs in the separate `mongo:6.0` compose container — we only need
#     the client shell here.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
        libsctp1 libgnutls30 libgcrypt20 libssl3 libidn12 \
        libmongoc-1.0-0 libbson-1.0-0 libyaml-0-2 \
        libmicrohttpd12 libcurl3-gnutls libnghttp2-14 \
        libtins4.0 libtalloc2 libpcap0.8 \
        libstdc++6 \
        iproute2 iptables \
        iputils-ping net-tools tcpdump traceroute iperf3 \
        python3 python3-pip python3-setuptools && \
    rm -rf /var/lib/apt/lists/*

# Node.js runtime (WebUI `npm run start`).
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# mongosh (MongoDB Shell) — official MongoDB apt repo. open5gs-dbctl uses it.
RUN curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc \
        | gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor && \
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" \
        > /etc/apt/sources.list.d/mongodb-org-8.0.list && \
    apt-get update && apt-get install -y --no-install-recommends mongodb-mongosh && \
    rm -rf /var/lib/apt/lists/*

# click is used by misc/db/python helpers in some provisioning flows (parity
# with the old base, which did `pip3 install click`).
RUN pip3 install --no-cache-dir --break-system-packages click

RUN update-ca-certificates

# Carry over only what runtime needs: the install tree, the built WebUI, and the
# DB tooling. Layout matches what open5gs_init.sh + the per-component init
# scripts expect (LD_LIBRARY_PATH=/open5gs/install/lib/<arch>-linux-gnu, configs
# copied into /open5gs/install/etc, dbctl at /open5gs/misc/db).
COPY --from=builder /open5gs/install /open5gs/install
COPY --from=builder /open5gs/src/webui /open5gs/webui
COPY --from=builder /open5gs/misc /open5gs/misc

WORKDIR /open5gs

# Preserve the original launch model exactly: COMPONENT_NAME picks the daemon,
# config is mounted at /mnt/<component>. Do NOT bake per-component config.
COPY open5gs_init.sh /
CMD ["/open5gs_init.sh"]
