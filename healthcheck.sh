#!/bin/sh
# healthcheck.sh — read-only quick status sweep of the docker_open5gs stack.
# Uses the best-practice tools (open5gs infoAPI + kamailio kamcmd), not log-grep.
# Run: ./healthcheck.sh
cd "$(dirname "$0")"
C="docker compose -f 4g-volte-deploy.yaml"
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$1"; }

echo "== containers =="
DOWN=$($C ps --format '{{.Name}} {{.Status}}' 2>/dev/null | grep -viE 'Up ' || true)
[ -z "$DOWN" ] && ok "all services Up" || { no "not Up:"; echo "$DOWN" | sed 's/^/      /'; }

echo "== EPC (open5gs) =="
if docker exec smf curl -sf "http://172.22.0.7:9091/metrics" >/dev/null 2>&1; then
  UES=$(docker exec smf curl -s "http://172.22.0.7:9091/metrics" 2>/dev/null | awk '/^ues_active /{print $2}')
  SESS=$(docker exec smf curl -s "http://172.22.0.7:9091/pdu-info?page=-1" 2>/dev/null | grep -o '"supi"' | wc -l)
  ok "SMF infoAPI ok — ues_active=$UES, UE-with-sessions=$SESS"
else no "SMF metrics/infoAPI unreachable (172.22.0.7:9091)"; fi

echo "== IMS (kamailio) =="
for r in pcscf scscf; do
  cmd=$( [ "$r" = pcscf ] && echo ulpcscf.status || echo ulscscf.status )
  REC=$(docker exec $r kamcmd $cmd 2>/dev/null | awk -F: '/Records/{gsub(/[ \t]/,"",$2);print $2;exit}')
  [ -n "$REC" ] && ok "$r registrations: $REC" || no "$r kamcmd failed"
done
PEERS=$(docker exec pcscf kamcmd cdp.list_peers 2>/dev/null | grep -c "I_Open" || echo 0)
PEERS2=$(docker exec scscf kamcmd cdp.list_peers 2>/dev/null | grep -c "I_Open" || echo 0)
ok "Diameter peers I_Open: pcscf=$PEERS scscf=$PEERS2  (pcscf→pcrf, scscf→hss)"

echo "== pyHSS =="
if docker exec pyhss sh -c 'grep -q ":0F23 .*0A" /proc/net/tcp 2>/dev/null'; then ok "Diameter listening :3875"; else no "Diameter NOT listening :3875 (check mysql/init)"; fi

echo "== MySQL =="
BLK=$(docker exec mysql mysql -sN -e "SHOW GLOBAL STATUS LIKE 'Aborted_connects'" 2>/dev/null | awk '{print $2}')
ok "reachable (aborted_connects=$BLK; if IMS DB errors: docker exec mysql mysql -e 'FLUSH HOSTS')"

echo "== active UE sessions (infoAPI) =="
docker exec smf curl -s "http://172.22.0.7:9091/pdu-info?page=-1" 2>/dev/null | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except: sys.exit()
for it in d.get("items",[]):
    for p in it.get("pdu",[]):
        print("   %-15s %-8s %-16s %s"%(it["supi"],p.get("apn","-"),p.get("ipv4","-"),p.get("ipv6","-")))
' 2>/dev/null
