# PyHSS (self-built, from source)

Self-built replacement for the original `pyhss` image — IMS HSS (Diameter Cx/Sh +
REST API), written in Python.

## What & versions

- **Upstream:** github.com/nickvsnetworking/pyhss, pinned to tag **1.0.2** (the latest
  release — PyHSS only ever cut 1.0.0/1.0.1/1.0.2; newer work is on `master`). Override
  with `--build-arg PYHSS_VERSION=master`.
- **Base: `python:3.11-alpine`.** Alpine is viable (the deploy's "能alpine就alpine" rule);
  the C-extension deps build fine on musl (`pysctp` against `lksctp-tools-dev`,
  `mysqlclient` against `mariadb-dev`; `aiohttp`/`pycryptodome` ship musllinux wheels).
  **Hard constraint is the Python version, not the distro:** `aiohttp==3.8.5` and
  `pysctp==0.7.2` only ship wheels up to **cp311** and don't build on 3.12+, so we pin
  Python 3.11 (`python:3.11-alpine`).

## Build

```bash
docker build -t open5gs_pyhss docker-image/pyhss
```

Multi-stage: a builder compiles the C-extension deps into a wheelhouse (gcc/headers
stay out of the runtime), the runtime installs the prebuilt wheels + ships the PyHSS
source at `/pyhss`.

## Run / integration

Generic image — deployment config + init are **mounted** at runtime (compose mounts
`./pyhss:/mnt/pyhss` and `CMD` runs `/mnt/pyhss/pyhss_init.sh`), same as the original.
The init waits for the separate `mysql` container, bootstraps the `pyhss` DB user,
renders `config.yaml`, starts a **local redis** (`redis-server --daemonize yes`), then
launches the API / Diameter / HSS services. Runtime image therefore ships `bash`,
`mariadb-client` (mysql/mysqladmin), `mariadb-connector-c`, `lksctp-tools`, `redis`.

To use it in `4g-volte-deploy.yaml`, point the `pyhss` service at this image
(`build: ./docker-image/pyhss` or `image: open5gs_pyhss`); keep the `./pyhss:/mnt/pyhss`
mount.

## Notes / gotchas

- `PyYAML==6.0` (hard-pinned in requirements.txt) fails to build with Cython 3 and has
  no musl cp311 wheel — the Dockerfile `sed`s it to `PyYAML==6.0.1` (a drop-in patch
  with a musl wheel). A pip `-c` constraint can't fix this: it conflicts with the hard
  `==` pin and yields `ResolutionImpossible`.
- The runtime stage does NOT re-clone PyHSS (no git in the slim image) — it
  `COPY --from=builder`s the source the builder already checked out, guaranteeing the
  same version as the wheelhouse.
- **Build-verified**: all tag-1.0.2 deps install incl. the C-extensions pysctp 0.7.2
  and mysqlclient 2.2.8; `redis-server`/`mysql`/`mysqladmin`/`bash` present;
  `/pyhss/services/*.py` in place. (pydantic is a *master*-only dep, not in 1.0.2.)
