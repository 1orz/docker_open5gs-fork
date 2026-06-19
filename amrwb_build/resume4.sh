#!/bin/bash
set -e
echo "[r4] install full FS build deps..."
apt-get install -y -qq libspeex-dev libspeexdsp-dev libpcre3-dev libedit-dev libldns-dev \
  libsqlite3-dev libcurl4-openssl-dev libssl-dev uuid-dev zlib1g-dev libtiff-dev libjpeg-dev \
  libopus-dev libsndfile1-dev libpng-dev >/dev/null 2>&1
ldconfig
cd /src/freeswitch
echo "[r4] FS configure..."
./configure --disable-dependency-tracking >/tmp/configure.log 2>&1
echo "[r4] make mod_amrwb..."
make -C src/mod/codecs/mod_amrwb >/tmp/make_amrwb.log 2>&1
echo "[r4] SO:"; find /src/freeswitch -name mod_amrwb.so
echo "[r4] ALL_DONE"
