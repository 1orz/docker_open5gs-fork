# =============================================================================
# Kamailio (IMS: P-CSCF / I-CSCF / S-CSCF / SMSC) — built from source on Alpine.
#
# WHY THIS IMAGE EXISTS
#   The deployment's IMS core ran the original ims_base image: ubuntu:jammy that
#   pinned an arbitrary kamailio 6.2.0-dev commit (ce087ee...) and, as a side
#   effect of `apt-get install mysql-server`, dragged a full local MariaDB server
#   + tcpdump/screen/tmux/ntp into every P/I/S-CSCF container. None of that is
#   used at runtime: the init scripts only talk to the SEPARATE mysql container
#   at ${MYSQL_IP} (172.22.0.17) via the mysql/mysqladmin *client* tools. This
#   image rebuilds kamailio from a real stable tag on a musl/Alpine base and
#   ships only what the four IMS roles actually need.
#
# BASE = ALPINE.  Kamailio has FIRST-PARTY Alpine packaging in-tree
#   (pkg/kamailio/alpine/APKBUILD, maintained by an Alpine dev) AND an official
#   Alpine package in the `main` repo. That APKBUILD builds the full IMS module
#   set — cdp, cdp_avp, ims_ipsec_pcscf, ims_registrar/usrloc_pcscf+scscf,
#   ims_qos, ims_icscf, ims_charging, ... — proving the IMS modules compile
#   cleanly against musl. Every build + runtime apk package below was verified
#   present on alpine:latest (3.23.x) via `apk add --simulate`. No hard
#   limitation was hit (see the radcli note below — it does NOT apply to us).
#
# VERSION = 6.1.3 (latest STABLE release; 6.1.0 Feb 2026 ... 6.1.3 May 2026).
#   The 6.2 line never shipped as stable — the old image's "6.2.0-dev" commit
#   became today's 6.1 stable branch. 6.0.x is now the *previous* stable series.
#   We pin a real release tag (ARG below) instead of a frozen -dev commit.
#   ims_ipsec_pcscf in 6.1.3 still exports the `ipsec_listen_addr6` modparam
#   (verified in src/modules/ims_ipsec_pcscf/ims_ipsec_pcscf_mod.c:
#     str ipsec_listen_addr6 = STR_NULL;
#     {"ipsec_listen_addr6", PARAM_STR, &ipsec_listen_addr6}
#   ) which pcscf/kamailio_pcscf.cfg relies on for dual-stack IPv6 IMS-AKA.
#
# RADIUS / radcli:  the Ubuntu image installed libradcli for the radius modules,
#   and radcli is awkward on Alpine (Alpine uses freeradius-client instead).
#   IRRELEVANT HERE: our modules.lst explicitly excludes acc_radius, auth_radius,
#   misc_radius, peering, osp — no radius module is built, so no radius client
#   library is needed at all. Nothing was dropped to make Alpine work.
#
# Build:  docker build -t docker_kamailio docker-image/kamailio
#   (4g-volte-deploy.yaml references the image as `docker_kamailio`.)
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: builder — compile kamailio + the IMS module set from source
# -----------------------------------------------------------------------------
FROM alpine:latest AS builder

# Pin to a real stable RELEASE tag for reproducibility. Use a branch name
# (e.g. "6.1") instead to always track the tip of the latest stable line.
ARG KAMAILIO_VERSION=6.1.3

# Build toolchain + dev headers. Each maps to a module group we actually build:
#   gcc/g++/make/flex/bison/linux-headers ... core compile
#   openssl-dev ........ tls, ims_ipsec_pcscf (IPsec SAs), tls.cfg
#   mariadb-dev ........ db_mysql (connects to the separate mysql container)
#   curl-dev ........... http_client, http_async_client, xcap_client
#   libxml2-dev ........ xmlops, xcap_server, presence_xml, all ims_* parsing
#   pcre2-dev .......... core regex engine (kamailio migrated pcre -> pcre2)
#   libmnl-dev ......... cdp / diameter peer plumbing
#   lksctp-tools-dev ... sctp transport (Diameter over SCTP)
#   json-c-dev ......... json module
#   jansson-dev ........ jansson, ims_charging
#   nghttp2-dev ........ nghttp2 module (HTTP/2)
#   libgcrypt-dev ...... cdp_avp / crypto helpers in the IMS auth path
#   libevent-dev ....... http_async_client event loop
#   util-linux-dev ..... libuuid for the uuid module
#   libunistring-dev ... unicode helpers pulled in by presence/xcap
RUN apk add --no-cache \
        git ca-certificates bash \
        gcc g++ make flex bison pkgconf linux-headers musl-dev \
        openssl-dev mariadb-dev curl-dev libxml2-dev pcre2-dev \
        libmnl-dev lksctp-tools-dev json-c-dev jansson-dev nghttp2-dev \
        libgcrypt-dev libevent-dev util-linux-dev libunistring-dev

# Fetch kamailio source (stable release tag / branch).
RUN mkdir -p /usr/local/src && cd /usr/local/src && \
    git clone --depth 1 -b ${KAMAILIO_VERSION} https://github.com/kamailio/kamailio

# Generate the build config, then overwrite the module selection with the exact
# IMS module list used by the original ims_base image (single source of truth).
RUN cd /usr/local/src/kamailio && make cfg
COPY modules.lst /usr/local/src/kamailio/src/modules.lst

# Compile + install (default prefix /usr/local):
#   binary  -> /usr/local/sbin/kamailio
#   modules -> /usr/local/lib64/kamailio/modules/*.so  (64-bit Alpine uses lib64)
#   kamctl SQL schemas -> /usr/local/share/kamailio/mysql/ (read at startup)
RUN cd /usr/local/src/kamailio && \
    make -j"$(nproc)" Q=0 all && \
    make install && \
    ldconfig /usr/local/lib64 2>/dev/null || true

# Strip symbols from the binary and every module — the main safe size win.
# `true` so a non-strippable artifact never fails the build.
RUN find /usr/local/lib64/kamailio -type f -name '*.so' -exec strip --strip-unneeded {} + ; \
    strip --strip-unneeded /usr/local/sbin/kamailio ; \
    true

# -----------------------------------------------------------------------------
# Stage 2: runtime — only the shared libs + tools the IMS init scripts need
# -----------------------------------------------------------------------------
FROM alpine:latest

# Runtime requirements (NO mysql-server — the DB is a separate container):
#   bash ............... kamailio_init.sh + each <role>_init.sh are #!/bin/bash
#                        and use [[ ]] / =~ regex (not POSIX ash compatible)
#   mariadb-client ..... the `mysql` / `mysqladmin` CLIs the init scripts run
#                        against ${MYSQL_IP} to create+seed the per-role schema
#   iproute2 ........... `ip r add` / `ip -6 r add` UE return routes in pcscf_init
#   musl runtime libs .. shared objects matching the -dev build deps above
RUN apk add --no-cache \
        bash mariadb-client iproute2 ca-certificates \
        libssl3 libcrypto3 mariadb-connector-c libcurl libxml2 \
        pcre2 libmnl lksctp-tools json-c jansson nghttp2-libs \
        libgcrypt libevent libuuid libunistring libstdc++

# Whole sbin: the kamailio daemon AND the admin tools — kamcmd (binrpc CLI for
# RPC status queries like ulpcscf.status / ulscscf.snapshot), kamctl, kamdbctl.
# (The earlier image shipped only the daemon, so there was no way to inspect
# registration state without grepping logs.) kamcmd talks to the binrpc unix
# socket the pcscf/scscf cfg sets up (/var/run/kamailio/kamailio_ctl).
COPY --from=builder /usr/local/sbin/              /usr/local/sbin/
COPY --from=builder /usr/local/lib64/kamailio/    /usr/local/lib64/kamailio/
COPY --from=builder /usr/local/share/kamailio/    /usr/local/share/kamailio/
COPY --from=builder /usr/local/etc/kamailio/      /usr/local/etc/kamailio/

# The init scripts hard-code SQL schema paths under the source tree. Provide both:
#  - utils/kamctl/mysql/*.sql  (standard/presence/ims_* schemas) -> make install
#    lays these under /usr/local/share/kamailio/mysql, so symlink the legacy path.
#  - misc/examples/ims/icscf/icscf.sql  is an EXAMPLE file that `make install`
#    does NOT install, yet icscf_init.sh reads it from the source tree path. Copy
#    that example tree verbatim from the builder so icscf bootstrap still works.
COPY --from=builder /usr/local/src/kamailio/misc/examples/ims/ \
                    /usr/local/src/kamailio/misc/examples/ims/
RUN mkdir -p /usr/local/src/kamailio/utils/kamctl && \
    ln -sf /usr/local/share/kamailio/mysql \
           /usr/local/src/kamailio/utils/kamctl/mysql && \
    ldconfig /usr/local/lib 2>/dev/null || true

# Preserve the original launch model: COMPONENT_NAME selects the role-specific
# init script mounted at /mnt/<role>/<role>_init.sh. Compose mounts ./pcscf etc.
# into /mnt and sets COMPONENT_NAME, so this image is a drop-in for ims_base.
COPY kamailio_init.sh /
CMD ["/kamailio_init.sh"]
