#!/bin/sh
# host-ue-routes.sh — add (or remove) host routes to the UE address pools via the UPF
# container, so the host CLI can reach the phones (ping/curl/etc).
#
# Why: UE IPs (internet 192.168.100.x / 2001:230:cafe::, ims 192.168.101.x /
# 2001:230:babe::) are NOT docker container IPs — they live on the UPF's GTP tun
# devices (ogstun/ogstun2). The host has no route to them by default. These routes
# point those pools at the UPF's docker address; UPF forwarding is already enabled.
#
# Not persistent (gone on reboot) — by design. Run manually:
#   sudo ./host-ue-routes.sh        # add routes (default)
#   sudo ./host-ue-routes.sh up     # add routes
#   sudo ./host-ue-routes.sh down   # remove routes
#
# Values are read from .env so they track the deployment config.
set -e
cd "$(dirname "$0")"

[ -f .env ] || { echo "ERROR: .env not found next to this script"; exit 1; }
get() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '\r'; }

UPF_IP=$(get UPF_IP)
UPF_IP6=$(get UPF_IP6)
V4_NET="$(get UE_IPV4_INTERNET) $(get UE_IPV4_IMS)"
V6_NET="$(get UE_IPV6_INTERNET) $(get UE_IPV6_IMS)"

[ -n "$UPF_IP" ] || { echo "ERROR: UPF_IP missing in .env"; exit 1; }

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
ACTION="${1:-up}"

case "$ACTION" in
  up|add)
    for n in $V4_NET; do
      [ -n "$n" ] && $SUDO ip   route replace "$n" via "$UPF_IP"  && echo "+ $n via $UPF_IP"
    done
    if [ -n "$UPF_IP6" ]; then
      for n in $V6_NET; do
        [ -n "$n" ] && $SUDO ip -6 route replace "$n" via "$UPF_IP6" && echo "+ $n via $UPF_IP6"
      done
    fi
    echo "done. test: ping <ue-ip>   (see UE IPs: docker exec smf curl -s http://${UPF_IP%.*}.7:9091/pdu-info?page=-1)"
    ;;
  down|del|remove)
    for n in $V4_NET; do [ -n "$n" ] && $SUDO ip   route del "$n" 2>/dev/null && echo "- $n" || true; done
    for n in $V6_NET; do [ -n "$n" ] && $SUDO ip -6 route del "$n" 2>/dev/null && echo "- $n" || true; done
    echo "removed."
    ;;
  *)
    echo "usage: $0 [up|down]"; exit 1;;
esac
