# =============================================================================
# rtpengine (Sipwise RTP media proxy) — built from source, userspace daemon only.
#
# Why this image exists: the docker_open5gs default rtpengine image pulls the
# prebuilt ngcp-rtpengine .deb from the dfx.at apt repo on top of debian:bookworm.
# This image instead compiles the daemon from upstream source at a pinned stable
# tag, so the deploy owns its own rtpengine build (mirrors the freeswitch image).
#
# Kernel module is DELIBERATELY NOT built. The in-kernel forwarder (xt_RTPENGINE /
# `iptables -j RTPENGINE`) is an out-of-tree netfilter module that must be compiled
# against the *running host kernel's* headers and inserted with modprobe — neither
# is possible from inside a container at build time. So we build the userspace
# daemon only. rtpengine then forwards media in userspace. This is the normal and
# supported mode for containerized rtpengine: with the default config the daemon
# tries kernel table 0, finds no module, and automatically falls back to userspace
# (see README). The mounted rtpengine_init.sh runs with TABLE=0 and does NOT pass
# --no-fallback by default, so the fallback path is taken cleanly.
#
# Base: alpine:3.21 (musl). The one historical blocker for Alpine — libjwt — is a
# non-issue here: rtpengine's lib/oauth.c uses the libjwt 1.x/2.x API (jwt_new,
# jwt_add_grant, jwt_encode_str), which libjwt 3.x removed. Alpine 3.21 ships
# libjwt 1.17.2 (1.x) as libjwt-dev, providing exactly that API. Every other dep
# (ffmpeg 6.1, glib, pcre2, hiredis, json-glib, libwebsockets 4.3, mosquitto 2.0,
# spandsp, liburing 2.8, libmnl, libnftnl, iptables/libiptc) is in the 3.21 main or
# community repos. No Debian fallback needed.
#
# Build:  docker build -t open5gs_rtpengine docker-image/rtpengine
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: builder — compile the userspace rtpengine daemon
# -----------------------------------------------------------------------------
FROM alpine:3.21 AS builder

ARG RTPENGINE_VERSION=mr13.5.1.16

# Build toolchain + all daemon build dependencies (development headers).
# - transcoding (kept ON, valuable for VoLTE AMR<->other): ffmpeg-dev pulls
#   libavcodec/format/util/swresample/filter; plus spandsp-dev, opus-dev.
# - libjwt-dev = 1.17.2 (1.x API) on 3.21 — the API lib/oauth.c expects.
# - iptables-dev provides the static libiptc/libxtables the daemon links against
#   (userspace control of the — here unused — kernel table); libmnl/libnftnl too.
# community repo (ffmpeg-dev, json-glib-dev, liburing-dev, libjwt-dev) is enabled
# by default in the official alpine images via /etc/apk/repositories.
RUN apk add --no-cache \
        git build-base linux-headers bash perl \
        pkgconf gperf \
        glib-dev zlib-dev openssl-dev pcre2-dev hiredis-dev \
        libcurl curl-dev libevent-dev libpcap-dev ncurses-dev \
        json-glib-dev libwebsockets-dev mosquitto-dev spandsp-dev opus-dev \
        ffmpeg-dev \
        libjwt-dev mariadb-dev \
        liburing-dev libmnl-dev libnftnl-dev iptables-dev xz-dev

WORKDIR /usr/src

# Clone at the pinned stable tag (shallow). Build ONLY the daemon: `make` inside
# the daemon/ subdir produces the `rtpengine` binary there (top-level make would
# also try the kernel module). We do NOT enter kernel-module/.
#   with_transcoding=yes  -> ffmpeg/spandsp/opus transcoding compiled in
#   without_nftables=yes  -> skip the nftables backend (kernel/netfilter only)
#   have_liburing=yes     -> link system liburing (2.8) instead of bundled copy
# bcg729 and codec-chain stay OFF: they're enabled only via DEB_BUILD_PROFILES,
# which we never set, so the deps.Makefile generator omits them.
# `make rtpengine` builds ONLY the binary target — avoids the `rtpengine.8` man-page
# rule, which needs pandoc (Error 127 otherwise). The man page is useless in-image.
RUN git clone --depth 1 -b ${RTPENGINE_VERSION} https://github.com/sipwise/rtpengine.git \
    && cd rtpengine/daemon \
    && with_transcoding=yes without_nftables=yes have_liburing=no make -j"$(nproc)" rtpengine \
    && strip --strip-unneeded rtpengine \
    && install -D -m 0755 rtpengine /usr/local/bin/rtpengine \
    && /usr/local/bin/rtpengine --version

# -----------------------------------------------------------------------------
# Stage 2: runtime — slim image with only the shared libs the daemon needs
# -----------------------------------------------------------------------------
FROM alpine:3.21

# Runtime shared libraries matching the build deps above, plus the network tools
# the mounted rtpengine_init.sh shells out to:
#   - bash         : init script is #!/bin/bash
#   - iproute2     : `ip route add ...` for the UE return routes (no NAT)
#   - iptables / nftables / kmod : present so the kernel-module path is *possible*
#     if a host ever provides xt_RTPENGINE; harmless (and unused) in userspace mode.
# ffmpeg runtime is split per-lib on Alpine (ffmpeg-libavcodec, -libavformat, ...).
RUN apk add --no-cache \
        bash iproute2 iptables nftables kmod \
        glib zlib openssl pcre2 hiredis \
        libcurl libevent libpcap ncurses-libs \
        json-glib libwebsockets mosquitto-libs spandsp opus \
        ffmpeg-libavcodec ffmpeg-libavformat ffmpeg-libavutil \
        ffmpeg-libswresample ffmpeg-libavfilter \
        libjwt mariadb-connector-c \
        liburing libmnl libnftnl

COPY --from=builder /usr/local/bin/rtpengine /usr/local/bin/rtpengine

# rtpengine dynamically links the legacy iptables C libs (libip4tc/libip6tc/libxtables)
# for kernel-table control. On Alpine these ship ONLY in iptables-dev (no runtime pkg),
# so copy them from the builder. COPY --from dereferences the SONAME symlink into a real
# file named libip*tc.so.2, which is exactly what the binary requests — version-agnostic.
COPY --from=builder /usr/lib/libip4tc.so.2   /usr/lib/libip4tc.so.2
COPY --from=builder /usr/lib/libip6tc.so.2   /usr/lib/libip6tc.so.2
COPY --from=builder /usr/lib/libxtables.so.12 /usr/lib/libxtables.so.12

# This image is GENERIC rtpengine — no deployment config baked in. The compose
# stack mounts ./rtpengine:/mnt/rtpengine and overrides the entrypoint to the
# mounted rtpengine_init.sh, which renders --interface/--listen-ng/etc. from env
# and execs `rtpengine`. The default CMD below makes the image usable standalone
# and matches what the init script execs (RUNTIME defaults to `rtpengine`).
CMD ["rtpengine", "--version"]
