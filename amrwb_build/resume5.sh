#!/bin/bash
set -e
cd /src/freeswitch
echo "[r5] trim modules.conf to ONLY mod_amrwb..."
cp modules.conf modules.conf.full
# 注释所有以字母开头的模块行,再只放开 mod_amrwb
sed -i 's/^\([a-zA-Z]\)/#\1/' modules.conf
sed -i '/mod_amrwb/s/^#//' modules.conf
echo "[r5] enabled modules:"; grep -vE '^\s*#|^\s*$' modules.conf
echo "[r5] FS configure..."
./configure --disable-dependency-tracking >/tmp/configure.log 2>&1
echo "[r5] make mod_amrwb..."
make -C src/mod/codecs/mod_amrwb >/tmp/make_amrwb.log 2>&1
echo "[r5] SO:"; find /src/freeswitch -name mod_amrwb.so
echo "[r5] ALL_DONE"
