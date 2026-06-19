#!/bin/bash
set -e
echo "[r3] install libpcre3-dev + others..."
apt-get install -y -qq libpcre3-dev libedit-dev libldns-dev libsqlite3-dev >/dev/null 2>&1
ldconfig
cd /src/freeswitch
echo "[r3] FS configure..."
./configure --disable-dependency-tracking >/tmp/configure.log 2>&1
echo "[r3] make mod_amrwb..."
make -C src/mod/codecs/mod_amrwb >/tmp/make_amrwb.log 2>&1
echo "[r3] SO:"; find /src/freeswitch -name mod_amrwb.so
echo "[r3] ALL_DONE"
