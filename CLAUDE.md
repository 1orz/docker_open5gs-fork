# CLAUDE.md — docker_open5gs (4G EPC + VoLTE/IMS + AI phone)

Single-host Open5GS **4G EPC** + **IMS/VoLTE** + AI voice bot, real **Baicells eNB**, MCC/MNC=**001/01**.
Compose file is **`4g-volte-deploy.yaml`** (NOT the default). Always:

```bash
docker compose -f 4g-volte-deploy.yaml <cmd>      # or: export COMPOSE_FILE=4g-volte-deploy.yaml
```

## Network
- Docker net `docker_open5gs_default`, **dual-stack**: `172.22.0.0/24` + ULA `fd00:172:22::/64`.
- Static IPs per service, **v6 mirrors v4 last octet** (`172.22.0.21` → `fd00:172:22::21`). Defined in `.env` as `X_IP`/`X_IP6`.
- UE pools (UPF `ogstun`/`ogstun2`, behind GTP — host has no route by default): internet `192.168.100.0/24`+`2001:230:cafe::/48`, ims `192.168.101.0/24`+`2001:230:babe::/48`.
- Domains: `ims.mnc001.mcc001.3gppnetwork.org`, `epc.mnc001...`.

## Services / images / IPs
One generic image serves many roles via `COMPONENT_NAME` (baked init dispatches to mounted `./<svc>/<svc>_init.sh`). Per-svc **config is mounted** (`./<svc>:/mnt/<svc>`), not baked.

| Image | Services | IP (.x / ::x) |
|---|---|---|
| `cloudorz/open5gs:2.7.7` | hss·mme·sgwc·sgwu·smf·upf·pcrf·webui | 3·9·5·6·7·8·4·26 |
| `cloudorz/kamailio:6.1.3` | icscf·scscf·pcscf·smsc | 19·20·21·33 |
| `cloudorz/pyhss:1.0.2` | pyhss | 18 |
| `cloudorz/rtpengine:mr13.5.1.16` | rtpengine (userspace, entrypoint=mounted init) | 16 |
| `cloudorz/freeswitch:1.11.1` | freeswitch (AI AS; mod_amrwb/audio_stream/verto) | 51 |
| local `docker_dns`/`docker_mysql`/`docker_metrics` | dns·mysql·metrics | 15·17·36 |
| `mongo:6.0`·grafana·`zarya/pyhss-gui`·`open5gs_voicebridge` | mongo·grafana·pyhss-gui·voice-bridge | 2·39·50·56 |

Dockerfiles for the self-built `cloudorz/*` live in `docker-image/<proj>/` (generic image, config mounted). `dns`/`mysql`/`metrics` still build locally from `./<svc>/`.

## Two HSS (don't confuse)
- **open5gs `hss`** (MongoDB, S6a) — controls **attach + data**. Subscribers in `mongo`; APN session `type`: 1=IPv4, 2=IPv6, **3=dual**.
- **`pyhss`** (MySQL `ims_hss_db`, Cx/Sh on **3868→bind 3875**) — controls **VoLTE/SMS auth+routing**. Talks Diameter to icscf/scscf.

## Call/data paths
- **VoLTE**: UE → P-CSCF (`pcscf`, IMS-AKA+IPsec) → I-CSCF → pyHSS(Cx) → S-CSCF; media via `rtpengine`; QoS via `pcscf`→`pcrf` (Rx). AMR-WB HD.
- **AI phone 5001**: iFC routes 5001→`freeswitch`; dialplan `uuid_audio_stream` → `voice-bridge:8090` (ws) → Doubao realtime speech.

## Observability (realtime, NOT log-grep)
```bash
./healthcheck.sh                                  # one-shot read-only status sweep of the whole stack
# UE sessions + assigned IPs (internet & ims, v4 & v6, QoS) — open5gs infoAPI
docker exec smf curl -s "http://172.22.0.7:9091/pdu-info?page=-1"
# IMS registrations + Diameter peers
docker exec pcscf kamcmd ulpcscf.dump        # scscf: kamcmd ulscscf.snapshot
docker exec pcscf kamcmd cdp.list_peers      # peer State I_Open = connected
# aggregate → Grafana localhost:3000 (open5gs/open5gs), Prometheus /metrics
# reach UEs from host CLI:  sudo ./host-ue-routes.sh   then ping <ue-ip>
```

## Known gotchas / fixes
- **MySQL TLS (new alpine clients)**: mariadb-client verifies MySQL-8's self-signed cert → init loops fail, host gets blocked. FIX (already in init scripts): `/etc/my.cnf` `[client]\nskip-ssl`. If "Host '…' blocked": `docker exec mysql mysql -e "FLUSH HOSTS"` (max_connect_errors raised to 100000).
- **IPv6 VoLTE registration fails** (`ims_qos check_ip_version GetAddrInfo error`): pcscf must have `modparam("ims_qos","recv_mode",0)` — recv_mode=1 feeds the *bracketed* IPv6 Via host to getaddrinfo (fails). NOT a musl/Alpine issue. IMS APN must be `type:3` in mongo for v6.
- **kamailio admin**: `kamcmd`/`kamctl` are in the image (added 2026-06). kamailio logs go to stdout (`docker logs`); open5gs daemons have **no `pgrep`** — check via `docker logs` or infoAPI.
- **Recreating** pcscf/scscf/mme drops handset registrations — toggle airplane mode to re-register. Validate config edits with `docker compose -f 4g-volte-deploy.yaml config` before recreating.
