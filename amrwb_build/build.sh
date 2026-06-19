#!/bin/bash
set -e
echo "[build] installing deps..."
apt-get update -qq
apt-get install -y -qq git build-essential automake autoconf libtool pkg-config \
  libssl-dev libcurl4-openssl-dev libspeexdsp-dev libsqlite3-dev libpcre2-dev \
  libedit-dev libldns-dev uuid-dev zlib1g-dev yasm libopus-dev \
  libopencore-amrwb-dev libvo-amrwbenc-dev >/dev/null 2>&1
echo "[build] cloning FreeSWITCH v1.10.12 (shallow)..."
cd /src
git clone --depth 1 -b v1.10.12 https://github.com/signalwire/freeswitch.git >/dev/null 2>&1
cd freeswitch
cp /usr/include/opencore-amrwb/dec_if.h src/mod/codecs/mod_amrwb/
cp /usr/include/vo-amrwbenc/enc_if.h src/mod/codecs/mod_amrwb/
echo "[build] bootstrap..."
./bootstrap.sh -j >/tmp/bootstrap.log 2>&1
sed -i '/codecs\/mod_amrwb/s/^#//' modules.conf
echo "[build] configure (this is the long part)..."
./configure --disable-dependency-tracking --disable-system-xmlrpc-c >/tmp/configure.log 2>&1
echo "[build] make mod_amrwb..."
make -C src/mod/codecs/mod_amrwb >/tmp/make_amrwb.log 2>&1
echo "[build] DONE. mod_amrwb.so:"
find /src/freeswitch -name "mod_amrwb.so"
echo "[build] amrwb runtime libs:"
ls -l /usr/lib/x86_64-linux-gnu/libopencore-amrwb.so.0 /usr/lib/x86_64-linux-gnu/libvo-amrwbenc.so.0
echo "[build] ALL_DONE"
