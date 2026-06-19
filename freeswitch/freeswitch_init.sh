#!/bin/sh
# FreeSWITCH IMS AS init for docker_open5gs — layout-agnostic.
#
# Works against BOTH:
#   - the third-party safarov/freeswitch image   (/etc/freeswitch, /usr/lib/freeswitch/mod,
#     /usr/bin/freeswitch) — here mod_amrwb/mod_audio_stream must be copied in at runtime
#   - our self-built image docker-image/freeswitch (/usr/local/freeswitch/...) — here those
#     modules are already compiled into the image, so nothing is copied, only autoloaded
#
# Overlays our IMS SIP profile + dialplan, autoloads the AI/HD-voice modules,
# substitutes IMS_DOMAIN / FREESWITCH_IP / SCSCF_IP / VOICEBRIDGE_IP, and launches FS.
set -e

# --- Detect FreeSWITCH layout -------------------------------------------------
if [ -x /usr/local/freeswitch/bin/freeswitch ]; then
    FS_ETC=/usr/local/freeswitch/conf
    FS_MOD=/usr/local/freeswitch/mod          # source build: modules live in $prefix/mod
    FS_BIN=/usr/local/freeswitch/bin/freeswitch
    VANILLA=                       # source build: make install already populated conf
else
    FS_ETC=/etc/freeswitch
    FS_MOD=/usr/lib/freeswitch/mod
    FS_BIN=/usr/bin/freeswitch
    VANILLA=/usr/share/freeswitch/conf/vanilla
fi
MODCONF=${FS_ETC}/autoload_configs/modules.conf.xml

# --- Build the IMS home domain like the other open5gs components --------------
if [ "${#MNC}" = "3" ]; then
    IMS_DOMAIN="ims.mnc${MNC}.mcc${MCC}.3gppnetwork.org"
else
    IMS_DOMAIN="ims.mnc0${MNC}.mcc${MCC}.3gppnetwork.org"
fi

# --- Seed vanilla config on first run (safarov only; source build ships it) ---
if [ ! -f "${FS_ETC}/freeswitch.xml" ] && [ -n "${VANILLA}" ]; then
    mkdir -p ${FS_ETC}
    cp -rf ${VANILLA}/* ${FS_ETC}/
fi

# --- Remove vanilla profiles/dialplan so nothing else grabs port 5060 ---------
rm -f  ${FS_ETC}/sip_profiles/*.xml
rm -rf ${FS_ETC}/sip_profiles/internal ${FS_ETC}/sip_profiles/external
rm -f  ${FS_ETC}/dialplan/default.xml ${FS_ETC}/dialplan/public.xml ${FS_ETC}/dialplan/skinny-patterns.xml
rm -rf ${FS_ETC}/dialplan/default ${FS_ETC}/dialplan/public ${FS_ETC}/dialplan/skinny-patterns

# --- Drop in our IMS config ---------------------------------------------------
cp /mnt/freeswitch/conf/sip_profiles/ims.xml   ${FS_ETC}/sip_profiles/ims.xml
cp /mnt/freeswitch/conf/dialplan/ims_conf.xml  ${FS_ETC}/dialplan/ims_conf.xml
# WebRTC (mod_verto) profile — only meaningful where mod_verto is present
[ -f /mnt/freeswitch/conf/autoload_configs/verto.conf.xml ] && \
    cp /mnt/freeswitch/conf/autoload_configs/verto.conf.xml ${FS_ETC}/autoload_configs/verto.conf.xml

# --- Modules: on safarov copy the .so in; on self-built they're baked --------
if [ ! -x /usr/local/freeswitch/bin/freeswitch ]; then
    [ -f /mnt/freeswitch/mod_audio_stream.so ] && cp /mnt/freeswitch/mod_audio_stream.so ${FS_MOD}/
    if [ -f /mnt/freeswitch/mod_amrwb.so ]; then
        cp /mnt/freeswitch/mod_amrwb.so ${FS_MOD}/
        cp -P /mnt/freeswitch/libopencore-amrwb.so* /usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
        cp -P /mnt/freeswitch/libvo-amrwbenc.so*    /usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
        ldconfig 2>/dev/null || true
    fi
fi

# Autoload our extra modules, but only those actually present in this image
# (safarov lacks mod_verto -> skipped without error; self-built image has all three).
for m in mod_amrwb mod_audio_stream mod_verto; do
    if [ -f ${FS_MOD}/${m}.so ] && ! grep -q "\"$m\"" ${MODCONF}; then
        sed -i "s#</modules>#  <load module=\"$m\"/>\n</modules>#" ${MODCONF}
    fi
done

# --- Substitute deployment variables ------------------------------------------
for f in ${FS_ETC}/sip_profiles/ims.xml ${FS_ETC}/dialplan/ims_conf.xml \
         ${FS_ETC}/autoload_configs/verto.conf.xml; do
    [ -f "$f" ] || continue
    sed -i "s|IMS_DOMAIN|${IMS_DOMAIN}|g"           "$f"
    sed -i "s|FREESWITCH_IP|${FREESWITCH_IP}|g"     "$f"
    sed -i "s|SCSCF_IP|${SCSCF_IP}|g"               "$f"
    sed -i "s|VOICEBRIDGE_IP|${VOICEBRIDGE_IP}|g"   "$f"
    sed -i "s|DOCKER_HOST_IP|${DOCKER_HOST_IP}|g"   "$f"
done

echo "[freeswitch_init] FS_BIN=${FS_BIN} IMS_DOMAIN=${IMS_DOMAIN} FREESWITCH_IP=${FREESWITCH_IP}"
exec ${FS_BIN} -nc -nf -nonat
