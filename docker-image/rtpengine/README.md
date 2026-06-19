# rtpengine — self-built image (userspace daemon)

Self-built Docker image for [Sipwise **rtpengine**](https://github.com/sipwise/rtpengine),
the RTP/media proxy used by the Kamailio P-CSCF in this VoLTE stack. Replaces the
default image (which pulls the prebuilt `ngcp-rtpengine` `.deb` from the dfx.at apt
repo onto `debian:bookworm`) with a from-source build at a pinned stable tag.

## Version

| Item | Value |
|------|-------|
| rtpengine | **mr13.5.1.16** (latest stable / "Latest"-tagged release as of 2026-06) |
| Base image | **alpine:3.21** (musl) |
| Build | userspace daemon only, transcoding ON, in-kernel module skipped |

> Note: `mr26.x` tags exist on the releases page but are a development/pre-release
> line; `mr13.5.1.16` is the tag GitHub marks as "Latest" (stable). Bump
> `RTPENGINE_VERSION` to retarget.

## Base choice: Alpine — and why it works

The user's preference is Alpine unless a hard constraint forces Debian. There is
**no such constraint** here — every rtpengine daemon dependency is in Alpine 3.21:

| Dependency | Alpine 3.21 pkg | Version | Repo |
|------------|-----------------|---------|------|
| ffmpeg (avcodec/format/util/swresample/filter) | `ffmpeg-dev` | 6.1.2 (≥ 6:10 required) | community |
| GLib + json-glib | `glib-dev`, `json-glib-dev` | 1.10.6 | main / community |
| PCRE2 | `pcre2-dev` | — | main |
| hiredis (redis) | `hiredis-dev` | 1.x | main |
| libwebsockets | `libwebsockets-dev` | 4.3.3 | main |
| mosquitto (MQTT) | `mosquitto-dev` | 2.0.20 | main |
| spandsp | `spandsp-dev` | 0.0.6 | main |
| opus | `opus-dev` | — | main |
| **libjwt** | `libjwt-dev` | **1.17.2 (1.x)** | community |
| liburing (≥ 2.3) | `liburing-dev` | 2.8 | main |
| libmnl / libnftnl | `libmnl-dev`, `libnftnl-dev` | — | main |
| iptables / libiptc | `iptables-dev` | 1.8.x | main |
| openssl, zlib, libcurl, libevent, libpcap, ncurses | standard | — | main |

### The libjwt landmine (the one real Alpine risk — and why it's fine on 3.21)

rtpengine's `lib/oauth.c` (used for the optional S3/HTTP OAuth feature) uses the
**libjwt 1.x/2.x API**: `jwt_new()`, `jwt_add_grant()`, `jwt_add_grant_int()`,
`jwt_encode_str()`, `JWT_ALG_INVAL`. libjwt **3.x removed these** in favour of a
new builder/checker API — which is exactly what broke the analogous Kamailio JWT
module on `alpine:edge` after it moved to libjwt 3.x
([kamailio#4264](https://github.com/kamailio/kamailio/issues/4264)). The flag
generator runs `pkg-config libjwt` **unconditionally**, so libjwt must be present
*and* expose the 1.x/2.x symbols or the link fails.

- `alpine:edge` ships `libjwt-dev` = **3.3.3** → would break the build. (edge does
  carry a compat `libjwt2-dev` = 2.1.3 providing `libjwt.pc`, but that's edge-only.)
- `alpine:3.21` ships `libjwt-dev` = **1.17.2** → the 1.x API rtpengine wants.

Pinning the base to **3.21** (not `alpine:latest`/edge) sidesteps the issue entirely
with a reproducible stable release. This is the reason for the explicit `3.21` tag.

## In-kernel forwarding: deliberately NOT built

The in-kernel forwarder (`xt_RTPENGINE`, used via `iptables -j RTPENGINE`) is an
out-of-tree netfilter module. It must be compiled against the **running host
kernel's** headers and inserted with `modprobe` on the host — neither is possible
from inside a container image at build time. So this image builds the **userspace
daemon only** (`cd daemon && make`), never `kernel-module/`.

This is the normal, supported containerized mode. The mounted `rtpengine_init.sh`:

- runs `modprobe xt_RTPENGINE` (a no-op/failure inside the container — harmless),
- sets `TABLE=0` (meaning "use in-kernel table 0"),
- does **not** pass `--no-fallback` unless `NO_FALLBACK=yes`.

With no module loaded, the daemon attempts table 0, finds nothing, and
**automatically falls back to userspace packet forwarding**. (`--no-fallback`
would instead make it refuse to start without the module — confirmed in
`daemon/main.c`: "Userspace fallback disallowed - exiting".) Userspace forwarding
is fully functional; it just costs more CPU per stream than the kernel path. To
get true in-kernel forwarding you would build/insert the DKMS module on the host
and run the container with the host network + `--privileged` — out of scope here.

## How the deployment uses this image

The image is **generic** — no config baked in. The compose stack mounts
`./rtpengine:/mnt/rtpengine` and overrides the entrypoint to the mounted
`rtpengine_init.sh`, which builds the option string from env vars
(`INTERFACE`, `INTERFACE6`, `LISTEN_NG`, `PORT_MIN/MAX`, `TABLE`, `TOS`,
`UE_IPV4_IMS`, `UPF_IP`, …) and `exec`s the daemon. Two requirements that shaped
this image:

- The binary must be named **`rtpengine`** on `PATH` — the init script's
  `RUNTIME=${1:-rtpengine}` execs exactly that. Installed at `/usr/local/bin/rtpengine`.
- The init script shells out to **`ip route add`** (iproute2) for the UE return
  routes (there is no NAT toward the UE subnets) and references `iptables`/`nftables`.
  All three are installed in the runtime stage.

## Build / structure

- **Multi-stage**: stage 1 (`build-base` toolchain) compiles only the daemon and
  strips the binary; stage 2 is a slim `alpine:3.21` with just the runtime `.so`s
  + `bash`, `iproute2`, `iptables`, `nftables`, `kmod`.
- **Build target `rtpengine`** (the binary only), NOT `make all` — `all` also builds
  the `rtpengine.8` man page via `pandoc`, which isn't installed (Error 127). The man
  page is useless in-image.
- **Make flags**: `with_transcoding=yes` (keep AMR/Opus/etc. transcoding),
  `without_nftables=yes` (nftables backend is kernel-side, unused in userspace),
  `have_liburing=no` — io_uring is **disabled**. With it on, the daemon objects
  reference `uring_*` symbols that the lib archive didn't include (lib/daemon flag
  mismatch) → `undefined reference` link errors. io_uring is only a kernel-path perf
  optimization (unused in userspace mode), so disabling it is the clean fix.
- **mariadb-dev** is a build dep: rtpengine's `deps.Makefile` requires `mysqlclient`
  (pkg-config) for the play-media-from-DB feature; `mariadb-connector-c` at runtime.
- **bcg729 / codec-chain stay off**: they're enabled only via
  `DEB_BUILD_PROFILES`, which we never set, so `deps.Makefile`'s flag generators
  omit them. (Matches the upstream `pkg.ngcp-rtpengine.nobcg729` profile the
  original Debian build used.)
- Binary is sanity-checked at build time with `rtpengine --version`.

### Build command

```bash
docker build -t open5gs_rtpengine docker-image/rtpengine
```

Retarget the version:

```bash
docker build --build-arg RTPENGINE_VERSION=mr13.5.1.16 \
    -t open5gs_rtpengine docker-image/rtpengine
```

## Gotchas

- **Pin `alpine:3.21`, never edge/latest** — edge's libjwt 3.x breaks the build
  (see above). If you bump the base, re-verify `libjwt-dev` is still 1.x/2.x.
- **ffmpeg is split per-library on Alpine** — the runtime stage installs
  `ffmpeg-libavcodec`, `ffmpeg-libavformat`, `ffmpeg-libavutil`,
  `ffmpeg-libswresample`, `ffmpeg-libavfilter` individually (no single
  `ffmpeg-libs` metapackage).
- **No kernel acceleration in-container** — expect userspace forwarding; do not set
  `NO_FALLBACK=yes` in the deployment env or the daemon will refuse to start.
- **`libip4tc`/`libip6tc`/`libxtables` are DYNAMICALLY linked** and Alpine has no
  runtime package for them (they ship only in `iptables-dev`; the `iptables` package
  does NOT include the `.so.2`). The runtime stage therefore `COPY --from=builder`s
  `libip4tc.so.2`, `libip6tc.so.2`, `libxtables.so.12` (COPY dereferences the SONAME
  symlink into a real file, version-agnostic). Without this the binary fails at startup
  with "Error loading shared library libip4tc.so.2". (The iptables/kernel control path
  is still unused in userspace mode — these libs just need to resolve at load time.)
- If you later need G.729, you'd add `bcg729` and pass the codec build flags — not
  needed for this VoLTE stack (AMR-WB is handled via the ffmpeg/spandsp path).
```
