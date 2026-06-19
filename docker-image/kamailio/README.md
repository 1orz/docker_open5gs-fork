# Kamailio (IMS core) — from-source Docker image

From-source build of [Kamailio](https://github.com/kamailio/kamailio) for the
IMS roles in this deployment — **P-CSCF, I-CSCF, S-CSCF, and SMSC** — on a slim
**Alpine** base. Drop-in replacement for the legacy `ims_base/` (ubuntu:jammy)
image: same `modules.lst`, same `kamailio_init.sh` launch model, so the existing
`4g-volte-deploy.yaml` works unchanged.

## Build

```bash
docker build -t open5gs_kamailio docker-image/kamailio
```

The deployment compose (`4g-volte-deploy.yaml`) references the image as
`docker_kamailio`, so to use it as a drop-in build with that tag:

```bash
docker build -t docker_kamailio docker-image/kamailio
```

Pin a specific point release instead of tracking the stable branch:

```bash
docker build --build-arg KAMAILIO_VERSION=6.1.1 -t docker_kamailio docker-image/kamailio
```

## Base: Alpine — and why

Per the project rule "能 alpine 就 alpine ... 除非硬性限制" (use Alpine unless a hard
limitation forces otherwise), this image uses **`alpine:3.21`**.

Alpine is not a guess here — Kamailio ships **first-party Alpine packaging**
in-tree at `pkg/kamailio/alpine/APKBUILD` (maintained by an Alpine Linux
developer). That APKBUILD compiles the **full IMS module set** against musl and
packages it as the `kamailio-ims` subpackage:

```
cdp  cdp_avp  ims_auth  ims_charging  ims_dialog  ims_diameter_server
ims_icscf  ims_ipsec_pcscf  ims_isc  ims_ocs  ims_qos  ims_registrar_pcscf
ims_registrar_scscf  ims_usrloc_pcscf  ims_usrloc_scscf
```

i.e. exactly the IMS modules our `modules.lst` requires. **No hard limitation was
hit**, so no fallback to Debian/Ubuntu was needed.

### The radcli "gotcha" that does NOT apply

The old Ubuntu image installed `libradcli` for the RADIUS modules, and radcli is
awkward on Alpine (Alpine's RADIUS modules use `freeradius-client` instead). This
is **irrelevant** for us: our `modules.lst` explicitly **excludes** every RADIUS
module (`acc_radius`, `auth_radius`, `misc_radius`, `peering`, `osp`), so no
RADIUS client library is built or installed. **Nothing was dropped to make Alpine
work** — the produced module set is identical to the Ubuntu build.

## Version: 6.1 (latest stable) — with `ipsec_listen_addr6` confirmed

- Default `ARG KAMAILIO_VERSION=6.1` tracks the **current stable branch**
  (Kamailio **6.1.0** released Feb 2026, **6.1.1** released Mar 2026). 6.0.x is
  now the *previous* stable series.
- This replaces the legacy image's frozen 6.2.0-**dev** commit
  (`ce087ee...`) with a real, supported stable release line.
- **`ipsec_listen_addr6` is present in 6.1.** Verified directly in
  `src/modules/ims_ipsec_pcscf/ims_ipsec_pcscf_mod.c`:

  ```c
  str ipsec_listen_addr6 = STR_NULL;
  ...
  {"ipsec_listen_addr6", PARAM_STR, &ipsec_listen_addr6},
  ```

  This is the dual-stack IPv6 IMS-AKA parameter that
  `pcscf/kamailio_pcscf.cfg` depends on:

  ```
  modparam("ims_ipsec_pcscf", "ipsec_listen_addr6", IPSEC_LISTEN_ADDR6)
  ```

  No version tradeoff: the feature the deployment relies on is in mainline
  stable, not just a -dev branch.

## What changed vs. the legacy `ims_base` image

| | legacy `ims_base` | this image |
|---|---|---|
| Base | ubuntu:jammy | alpine:3.21 |
| Kamailio | 6.2.0-dev pinned commit | 6.1 stable branch (ARG) |
| Build style | single stage | multi-stage (builder → runtime), symbols stripped |
| `mysql-server` | **installed** (full local MariaDB server) | **removed** — see below |
| Extra cruft | tcpdump, screen, tmux, ntp, dkms | none |

### `mysql-server` removed (it was dead weight)

The legacy image ran `apt-get install mysql-server`, baking a full MariaDB
**server** into every CSCF container. The init scripts never start a local DB —
they only run the `mysql` / `mysqladmin` **client** tools against the separate
`mysql` container at `${MYSQL_IP}` to create and seed each role's schema. This
image therefore installs only `mariadb-client`, not a server.

## Dependencies

**Build (`-dev`):** `gcc g++ make flex bison pkgconf linux-headers musl-dev`,
`openssl-dev` (tls, ims_ipsec_pcscf), `mariadb-dev` (db_mysql), `curl-dev`
(http_client/http_async_client/xcap_client), `libxml2-dev`
(xmlops/xcap_server/presence_xml/ims parsing), `pcre2-dev` (core regex),
`libmnl-dev` (cdp/diameter), `lksctp-tools-dev` (SCTP transport), `json-c-dev`
(json), `jansson-dev` (jansson/ims_charging), `nghttp2-dev` (nghttp2),
`libgcrypt-dev` (cdp_avp / IMS auth crypto), `libevent-dev` (http_async_client),
`util-linux-dev` (libuuid → uuid module), `libunistring-dev`.

**Runtime:** `bash` (init scripts are `#!/bin/bash` with `[[ ]]`/`=~`),
`mariadb-client` (`mysql`/`mysqladmin` CLIs), `iproute2` (`ip r add` UE return
routes in `pcscf_init.sh`), plus the matching musl shared libs: `libssl3
libcrypto3 mariadb-connector-c libcurl libxml2 pcre2 libmnl lksctp-tools json-c
jansson nghttp2-libs libgcrypt libevent libuuid libunistring libstdc++`.

## Launch model (unchanged)

`CMD ["/kamailio_init.sh"]`. The script reads `COMPONENT_NAME`
(`pcscf`/`icscf`/`scscf`/`smsc`, optionally numbered) and execs the matching
role init script mounted at `/mnt/<role>/<role>_init.sh`. Compose mounts
`./pcscf`, `./scscf`, `./icscf` into `/mnt` and sets `COMPONENT_NAME`, so this
image is a direct substitute for `ims_base`.

## Caveats / notes

- **kamctl SQL path shim.** The role init scripts read the table-creation SQL
  from `/usr/local/src/kamailio/utils/kamctl/mysql/*.sql` (the legacy in-source
  path). `make install` instead places those schemas under
  `/usr/local/share/kamailio/mysql/`. The image symlinks the legacy path to the
  installed one so the **unmodified** init scripts keep working. If a future
  Kamailio version relocates the SQL data dir, update that symlink.
- **`KAMAILIO_VERSION=6.1`** tracks the moving stable branch tip. For
  reproducible builds, pin a tag (e.g. `6.1.1`).
- **musl vs glibc.** This is a musl build. The IMS modules build and load on
  musl per Kamailio's own Alpine packaging; behavior is equivalent for this
  deployment's use, but it is a different libc than the legacy glibc image.
- **`privileged` / sysctl.** The P-CSCF still needs the container capabilities it
  had before (it sets `ip_nonlocal_bind` and adds routes); the compose service
  already runs it `privileged: true`, unchanged by this image.
```
