# FreeSWITCH (self-built, from source)

Replaces the third-party `safarov/freeswitch` image with one we build ourselves,
so the deployment owns its FreeSWITCH and ships the modules we actually need.

## What's baked in

- **FreeSWITCH 1.11.1** (latest, released 2026-05-26) — built from upstream source.
- **mod_amr** (AMR narrowband 8k) + **mod_amrwb** (AMR-WB 16k HD wideband) — the WB
  module is the whole reason this image exists; stock images omit it (patent-encumbered
  codecs, default-off in `modules.conf`).
- **mod_audio_stream** (amigniter, MIT) — realtime L16↔WebSocket bridge for the AI call.
- **mod_verto** — WebRTC signaling so a browser (verto.js) can place/receive calls.
  Depends on libks (already built); VP8 video via libvpx.
- Dependency chain built from GitHub source (token-free): **spandsp → sofia-sip →
  libks → signalwire-c** (sofia/spandsp were removed from the FS tree in 1.10.4; 1.11
  also requires libks≥2.0.11 + signalwire-c). A SignalWire token is only needed for
  prebuilt `.deb` packages — never for a source build.

## Build

```bash
docker build -t open5gs_freeswitch docker-image/freeswitch
```

Multi-stage: a `builder` stage compiles everything, the runtime stage carries only
the shared libs + `/usr/local/freeswitch`. Expect a long first build (FS core is large).
Override the version with `--build-arg FS_VERSION=v1.10.12` if you want the stable line.

## Run / integration

This image is **generic** — no deployment config baked in (same philosophy as the
`docker_open5gs` / `docker_kamailio` images: one image, config mounted per deployment).
The IMS SIP profile + dialplan and the `freeswitch_init.sh` that renders them live in
the repo's `freeswitch/` dir and are **mounted at runtime**. The init substitutes
`IMS_DOMAIN`/`FREESWITCH_IP`/`SCSCF_IP`/`VOICEBRIDGE_IP` and autoloads `mod_amrwb` +
`mod_audio_stream` (which are compiled into this image, so it no longer copies any
`.so` at runtime like the safarov setup did).

To use it in `4g-volte-deploy.yaml`, point the `freeswitch` service at this image and
keep the existing config mount + init entrypoint:

```yaml
  freeswitch:
    build: ./docker-image/freeswitch        # or image: open5gs_freeswitch
    volumes:
      - ./freeswitch:/mnt/freeswitch         # IMS config + init (mounted, not baked)
      - ./aibot/shared:/shared
    entrypoint: ["sh", "/mnt/freeswitch/freeswitch_init.sh"]
```

> `freeswitch/freeswitch_init.sh` must be updated for the source layout
> (`/usr/local/freeswitch/...` instead of safarov's `/etc/freeswitch`,
> `/usr/lib/freeswitch/mod`) and should drop the runtime `.so` copying since
> mod_amrwb + mod_audio_stream are now built into the image.

(Not wired into the running compose yet — this directory just produces the image.)

## Notes / caveats

- **Untested until first build.** Debian package names (`libavformat59`, `liblua5.2-0`,
  etc.) are pinned to **bookworm**; on Debian 13 trixie some `lib*` soname versions
  differ — adjust the runtime `apt-get` list if you switch the base image.
- The dep libs (spandsp/sofia/libks/signalwire-c) are cloned at **HEAD**. For
  reproducible builds, pin each to a known-good commit/tag.
- 1.11 migrated to PCRE2 and removed ~30 legacy modules; the codecs we use
  (AMR/AMR-WB/OPUS/PCMU/PCMA) are unaffected. If a future bump drops a module we rely
  on, check the 1.11.x release notes.

## WebRTC (mod_verto) — what's done vs what you still need

Built into the image; the `default-v4` verto profile lives in (mounted)
`freeswitch/conf/autoload_configs/verto.conf.xml` — ws on **8081**, wss on **8082**,
codecs opus/vp8/h264. `freeswitch_init.sh` copies it, substitutes
`FREESWITCH_IP`/`IMS_DOMAIN`/`DOCKER_HOST_IP`, and autoloads mod_verto **only when the
module is present** (so the current safarov image is unaffected — it has no mod_verto).

To actually place a browser call you still need:
1. **Publish the WS + media ports** on the `freeswitch` service in compose:
   `8081:8081/tcp`, `8082:8082/tcp`, and an RTP range (e.g. `16384-16484/udp`) with a
   matching `rtp-start/end` so ICE works from a LAN browser.
2. **wss cert** at `conf/ssl/wss.pem` (browsers need wss from https pages):
   `cd /usr/local/freeswitch && ./bin/gentls_cert setup -cn $DOMAIN` or drop a PEM
   (cert+key concatenated) at `conf/ssl/wss.pem`. Plain ws (8081) works from http/localhost.
3. **A login user**: verto authenticates against the FreeSWITCH directory
   (`conf/directory/default/*.xml`, vanilla demo users 1000–1019 / pass 1234). Add a user
   or reuse a demo one; `force-register-domain` is set to the IMS domain.
4. **The verto.js client**: ships in the FS source at `html5/verto/verto_communicator`
   (Angular demo) and `html5/verto/js` (the library). Serve it from any static web host
   and point it at `wss://<host>:8082`.
5. **ext-rtp-ip** is set to `DOCKER_HOST_IP` so ICE advertises a LAN-reachable candidate;
   for media across NAT you may also want a STUN/TURN server.

Browser → real SIM (WebRTC↔VoLTE) is a further step: the `ims` dialplan would need a
route that forwards a browser-originated call out to the S-CSCF. Not wired yet — the
above gets browser↔FreeSWITCH working first (e.g. a browser calling the 5001 AI bot).
