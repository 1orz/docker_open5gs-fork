# open5gs — self-built image

Self-built replacement for the prebuilt `docker_open5gs` base image. Builds
[open5gs](https://github.com/open5gs/open5gs) (4G EPC + 5G Core) from source at a
pinned stable tag, in a multi-stage build, and keeps the **exact same launch
model** as the original `base/` image so the existing compose files keep working
unchanged.

## Version

| Item | Value |
|------|-------|
| open5gs | **v2.7.7** — latest stable tag (released 2025-03-15; verified via `git ls-remote --tags github.com/open5gs/open5gs`). The old `base/Dockerfile` pinned an untagged commit `782a97e…`; this image moves to the newest released tag. |
| Base image | **debian:bookworm-slim** (builder and runtime) |
| Node.js | 20.x (NodeSource) — required by the Next.js WebUI |
| mongosh | from MongoDB official apt repo (`mongodb-org/8.0`, bookworm) |

Bump the version with `--build-arg OPEN5GS_VERSION=vX.Y.Z`.

## Base image — why Debian, not Alpine

The user's rule is "Alpine unless a hard constraint." Here open5gs **itself**
compiles cleanly on Alpine/musl (there is an official Alpine guide, and every
C/C++ dependency — lksctp, gnutls, libgcrypt, libidn, mongo-c-driver,
libmicrohttpd, curl, nghttp2, talloc, yaml — is in Alpine main/community). The
one dep usually feared as a musl blocker, **libtins**, is *not* a blocker:
open5gs ships a meson wrap (`subprojects/libtins.wrap`, verified present at
v2.7.7) so meson builds libtins from source automatically on any base.
`freeDiameter`, `prometheus-client-c`, and `usrsctp` are meson wraps too.

The **hard blocker is the MongoDB shell, not open5gs**:

- `hss/hss_init.sh` runs `ln -s /usr/bin/mongo /usr/bin/mongosh` and
  `misc/db/open5gs-dbctl` shells out to `mongosh --eval …` to provision
  subscribers (verified: 20+ `mongosh` call sites in `open5gs-dbctl`).
- MongoDB removed its server from Alpine after 3.9 (SSPL licensing), and there is
  **no musl build of `mongosh`** — the official binaries (npm/tarball) are
  glibc-only and fail on musl with `libc.so.6: cannot open shared object file`.
  The only Alpine work-arounds are glibc shims (`gcompat`, sgerrand) that are
  explicitly not production-grade.

Because this image must carry a working `mongosh` for the HSS/UDR/PCF
provisioning path, it uses Debian — same precedent as the FreeSWITCH image in
this repo. (If subscriber provisioning ever leaves this image, the base can flip
to `alpine:3.20` using the apk names noted in the Dockerfile header.)

## Key dependencies

**Build (builder stage):** `build-essential ninja-build meson cmake flex bison
pkg-config`, plus open5gs core deps `libsctp-dev libgnutls28-dev libgcrypt-dev
libssl-dev libidn11-dev libmongoc-dev libbson-dev libyaml-dev libmicrohttpd-dev
libcurl4-gnutls-dev libnghttp2-dev libtins-dev libtalloc-dev libpcap-dev`, plus
`nodejs` for the WebUI. (flex/bison are needed by the freeDiameter meson
subproject; cmake/libpcap by the libtins subproject.)

**Runtime (final stage):** the non-`-dev` shared libs that match the above
(`libsctp1 libgnutls30 libgcrypt20 libssl3 libidn12 libmongoc-1.0-0 libbson-1.0-0
libyaml-0-2 libmicrohttpd12 libcurl3-gnutls libnghttp2-14 libtins4.0 libtalloc2
libpcap0.8 libstdc++6`), the networking tools the init scripts use (`iproute2`
`iptables` for the `ogstun` device + NAT, plus `iputils-ping net-tools tcpdump
traceroute iperf3` for debugging parity), `nodejs`, `mongodb-mongosh`, and
`python3` + `click`. All runtime package names verified present in bookworm.

## Launch model (unchanged)

One generic image serves every NF. The baked `/open5gs_init.sh` reads
`COMPONENT_NAME` (e.g. `mme`, `smf`, `upf`, `hss`, `sgwc`, `sgwu`, `pcrf`,
`webui`, plus all 5GC NFs) and execs the matching per-component init script from
the mounted config: `/mnt/<component>/<COMPONENT_NAME>_init.sh`. **No
per-component config is baked** — compose mounts `./<comp>:/mnt/<comp>` at
runtime. `CMD` is `/open5gs_init.sh`.

Install layout matches what the init scripts expect:
`/open5gs/install/{bin,etc,lib,include}`, WebUI at `/open5gs/webui`, DB tooling
at `/open5gs/misc/db` (`open5gs-dbctl`).

## Gotchas

- **Network needed at build time.** `meson setup` fetches the wrap subprojects
  (freeDiameter, libtins, prometheus-client-c, usrsctp) over the network.
- **`mongo` vs `mongosh`.** MongoDB 6+ dropped the legacy `mongo` shell; this
  image ships `mongosh` (which `open5gs-dbctl` actually calls). `hss_init.sh`
  still runs `ln -s /usr/bin/mongo /usr/bin/mongosh`; that line fails harmlessly
  ("File exists", and no `set -e`) and is not needed — `mongosh` is already on
  `PATH`. The MongoDB *server* runs in the separate `mongo` compose container;
  this image carries only the client shell.
- **`libidn11-dev`.** On bookworm this is provided by the `libidn` source; the
  upstream guide picks `libidn-dev` or `libidn11-dev` depending on the distro.
  bookworm has `libidn11-dev` (build) → `libidn12` (runtime), both used here.
- **Strip step** removes ~debug symbols from `/open5gs/install/{bin,lib}` in the
  builder before copying, for a smaller runtime image.

## Build

The Dockerfile uses a **self-contained build context** — `open5gs_init.sh` is
copied into this directory (a duplicate of `base/open5gs_init.sh`), so the build
context is just this folder. From the repo root:

```sh
docker build -t open5gs_open5gs docker-image/open5gs
```

The compose files reference the image as `docker_open5gs` — tag to match your
compose `image:` field, e.g.:

```sh
docker build -t docker_open5gs docker-image/open5gs
```

Pin a different open5gs version:

```sh
docker build --build-arg OPEN5GS_VERSION=v2.7.6 -t open5gs_open5gs docker-image/open5gs
```
