#!/bin/bash
set -e
echo "[deps] extra build tools..."
apt-get install -y -qq cmake libtiff-dev libssl-dev uuid-dev zlib1g-dev libjpeg-dev >/dev/null 2>&1
cd /src
# 1) libks (SignalWire 核心基础库, 开源)
echo "[deps] building libks..."
git clone --depth 1 https://github.com/signalwire/libks.git >/dev/null 2>&1 || true
cd libks && cmake -DCMAKE_INSTALL_PREFIX=/usr -DWITH_LIBBACKTRACE=0 . >/tmp/libks_cmake.log 2>&1 && make -j2 >/tmp/libks_make.log 2>&1 && make install >/dev/null 2>&1
cd /src
# 2) sofia-sip (开源)
echo "[deps] building sofia-sip..."
git clone --depth 1 https://github.com/freeswitch/sofia-sip.git >/dev/null 2>&1 || true
cd sofia-sip && ./bootstrap.sh >/tmp/sofia_boot.log 2>&1 && ./configure --prefix=/usr >/tmp/sofia_conf.log 2>&1 && make -j2 >/tmp/sofia_make.log 2>&1 && make install >/dev/null 2>&1
cd /src
# 3) spandsp (FS 分支, 开源)
echo "[deps] building spandsp..."
git clone --depth 1 https://github.com/freeswitch/spandsp.git >/dev/null 2>&1 || true
cd spandsp && ./bootstrap.sh >/tmp/spandsp_boot.log 2>&1 && ./configure --prefix=/usr >/tmp/spandsp_conf.log 2>&1 && make -j2 >/tmp/spandsp_make.log 2>&1 && make install >/dev/null 2>&1
ldconfig
echo "[deps] DEPS_DONE"
# 4) FS configure + mod_amrwb
cd /src/freeswitch
echo "[deps] FS configure..."
PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig ./configure --disable-dependency-tracking >/tmp/configure.log 2>&1
echo "[deps] make mod_amrwb..."
make -C src/mod/codecs/mod_amrwb >/tmp/make_amrwb.log 2>&1
echo "[deps] SO:"; find /src/freeswitch -name mod_amrwb.so
echo "[deps] ALL_DONE"
