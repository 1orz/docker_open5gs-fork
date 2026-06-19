#!/bin/bash
set -e
echo "[resume] install libtool-bin..."
apt-get install -y -qq libtool-bin >/dev/null 2>&1
cd /src/freeswitch
cp /usr/include/opencore-amrwb/dec_if.h src/mod/codecs/mod_amrwb/ 2>/dev/null || true
cp /usr/include/vo-amrwbenc/enc_if.h src/mod/codecs/mod_amrwb/ 2>/dev/null || true
echo "[resume] bootstrap..."
./bootstrap.sh -j >/tmp/bootstrap.log 2>&1
sed -i '/codecs\/mod_amrwb/s/^#//' modules.conf
echo "[resume] configure (slow)..."
./configure --disable-dependency-tracking --disable-system-xmlrpc-c >/tmp/configure.log 2>&1
echo "[resume] make mod_amrwb..."
make -C src/mod/codecs/mod_amrwb >/tmp/make_amrwb.log 2>&1
echo "[resume] DONE so:"; find /src/freeswitch -name "mod_amrwb.so"
echo "[resume] ALL_DONE"
