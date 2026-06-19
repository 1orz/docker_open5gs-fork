# =============================================================================
# FreeSWITCH 1.11.1 — built entirely from source (token-free).
#
# Why this image exists: the third-party safarov/freeswitch image ships mod_amr
# (8k narrowband) but NOT mod_amrwb (16k HD wideband), and not mod_audio_stream
# (the realtime AI bridge module). This image builds FreeSWITCH from upstream
# source with both baked in, so the deploy owns its own FreeSWITCH.
#
# Dependency reality (FreeSWITCH 1.10.4+): sofia-sip and spandsp were removed
# from the FS tree; 1.11 also needs libks (>=2.0.11) and signalwire-c. SignalWire's
# apt repo is token-gated since 2024 — so we build all four from GitHub source.
# A SignalWire token is ONLY needed for prebuilt packages, never for source.
# Build order is mandatory: spandsp -> sofia-sip -> libks -> signalwire-c -> FS.
#
# Build:  docker build -t open5gs_freeswitch docker-image/freeswitch
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: builder — compile the dep chain + FreeSWITCH + mod_audio_stream
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS builder

ARG FS_VERSION=v1.11.1
ENV DEBIAN_FRONTEND=noninteractive

# Build toolchain + FreeSWITCH build dependencies (1.11: PCRE2, ffmpeg, no legacy).
# AMR codecs need: libopencore-amrnb-dev (mod_amr), libopencore-amrwb-dev +
# libvo-amrwbenc-dev (mod_amrwb). mod_audio_stream needs libevent + libspeexdsp.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates wget build-essential automake autoconf libtool libtool-bin \
        pkg-config cmake yasm uuid-dev \
        libssl-dev libsqlite3-dev libcurl4-openssl-dev libldns-dev \
        libspeexdsp-dev libspeex-dev libedit-dev libtiff-dev libopus-dev \
        liblua5.2-dev libpq-dev libsndfile-dev libpcre2-dev \
        libavformat-dev libswscale-dev libavcodec-dev libavutil-dev \
        zlib1g-dev libjpeg-dev libevent-dev libvpx-dev \
        libopencore-amrnb-dev libopencore-amrwb-dev libvo-amrwbenc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src

# 1) SpanDSP (FreeSWITCH fork) ------------------------------------------------
RUN git clone --depth 1 https://github.com/freeswitch/spandsp.git \
    && cd spandsp && ./bootstrap.sh && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" && make install && ldconfig

# 2) Sofia-SIP (FreeSWITCH fork) ----------------------------------------------
RUN git clone --depth 1 https://github.com/freeswitch/sofia-sip.git \
    && cd sofia-sip && ./bootstrap.sh && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" && make install && ldconfig

# 3) libKS (SignalWire foundational lib, required by 1.11) --------------------
#    NOTE: full clone (no --depth 1) — libks' CMake runs `git describe` to build a
#    Debian changelog; a shallow clone has no tags and that step fails the configure.
RUN git clone https://github.com/signalwire/libks.git \
    && cd libks && cmake -DCMAKE_INSTALL_PREFIX=/usr/local -DWITH_LIBBACKTRACE=0 . \
    && make -j"$(nproc)" && make install && ldconfig

# 4) signalwire-c (required by 1.11 master line) ------------------------------
RUN git clone https://github.com/signalwire/signalwire-c.git \
    && cd signalwire-c && PKG_CONFIG_PATH=/usr/local/lib/pkgconfig cmake -DCMAKE_INSTALL_PREFIX=/usr/local . \
    && make -j"$(nproc)" && make install && ldconfig

# 5) FreeSWITCH core + modules ------------------------------------------------
#    Enable the two AMR codec modules (commented out by default in modules.conf).
#    $-anchored seds so 'mod_amr' does not also match the 'mod_amrwb' line.
RUN git clone --depth 1 -b ${FS_VERSION} https://github.com/signalwire/freeswitch.git \
    && cd freeswitch \
    && ./bootstrap.sh -j \
    && sed -i 's|^#codecs/mod_amr$|codecs/mod_amr|'         modules.conf \
    && sed -i 's|^#codecs/mod_amrwb$|codecs/mod_amrwb|'     modules.conf \
    && sed -i 's|^#endpoints/mod_verto$|endpoints/mod_verto|' modules.conf \
    && PKG_CONFIG_PATH=/usr/local/lib/pkgconfig ./configure --disable-dependency-tracking \
    && make -j"$(nproc)" \
    && make install

# 6) mod_audio_stream (amigniter, MIT) — realtime L16<->WebSocket bridge -------
#    Third-party module, not in the FS tree. Built against our freshly-installed
#    FreeSWITCH via pkg-config. Uses an in-house libevent-based ws client (libwsc,
#    a git submodule) — no libwebsockets needed.
RUN git clone --recurse-submodules https://github.com/amigniter/mod_audio_stream.git \
    && cd mod_audio_stream && mkdir build && cd build \
    && PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig cmake -DCMAKE_BUILD_TYPE=Release .. \
    && make -j"$(nproc)" && make install

# 7) Strip debug symbols — the single biggest safe size win (an unstripped FS
#    build carries hundreds of MB of symbols). Real files only (-type f skips the
#    .so symlinks); trailing `true` so a non-strippable file never fails the build.
RUN find /usr/local/freeswitch /usr/local/lib -type f \( -name '*.so' -o -name '*.so.*' \) \
        -exec strip --strip-unneeded {} + ; \
    strip --strip-unneeded /usr/local/freeswitch/bin/freeswitch ; \
    true

# -----------------------------------------------------------------------------
# Stage 2: runtime — slim image with only the shared libs FreeSWITCH needs
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV FS_HOME=/usr/local/freeswitch
ENV PATH=$FS_HOME/bin:$PATH

# Runtime shared libraries (non -dev) matching the build deps above.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3 libsqlite3-0 libcurl4 libldns3 \
        libspeexdsp1 libspeex1 libedit2 libtiff6 libopus0 \
        liblua5.2-0 libpq5 libsndfile1 libpcre2-8-0 \
        libavformat59 libswscale6 libavcodec59 libavutil57 \
        zlib1g libjpeg62-turbo libevent-2.1-7 libevent-pthreads-2.1-7 libuuid1 libvpx7 \
        libopencore-amrnb0 libopencore-amrwb0 libvo-amrwbenc0 \
    && rm -rf /var/lib/apt/lists/*

# Bring over the custom-built libs (spandsp/sofia/libks/signalwire-c) and FS itself.
COPY --from=builder /usr/local/lib/        /usr/local/lib/
COPY --from=builder /usr/local/freeswitch/ /usr/local/freeswitch/
RUN ldconfig

EXPOSE 5060/udp 5060/tcp

# This image is GENERIC FreeSWITCH — no deployment config baked in. Just like the
# docker_open5gs / docker_kamailio images, the per-deployment config + init script
# are mounted at runtime (compose mounts ./freeswitch:/mnt/freeswitch and sets the
# entrypoint to the mounted freeswitch_init.sh, which renders the IMS profile/dialplan
# with the right IPs/domain and launches FS). The default CMD below just runs vanilla
# FreeSWITCH so the image is also usable standalone.
CMD ["freeswitch", "-nc", "-nf", "-nonat"]
