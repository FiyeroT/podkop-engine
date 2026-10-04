#!/bin/sh
# Switching between podkop-engine and podkop-engine-full in an OpenWrt image (x86_64), with
# podkop installed and /etc/config/sing-box changed by hand: the change must survive both ways.
#
#   docker run --rm -v <dir with both packages>:/pkgs:ro -v <repo>/lab:/lab:ro \
#     openwrt/rootfs:x86-64-24.10.8 sh /lab/switch-test.sh      (ipk)
#     openwrt/rootfs:x86-64-25.12.5 ...                         (apk)
set -eu
PODKOP_VERSION=${PODKOP_VERSION:-0.7.22}
REL=https://github.com/itdoginfo/podkop/releases/download/$PODKOP_VERSION
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p /var/lock /tmp/pk

expect() { # <package>
  sing-box version | grep -q 'podkop_slim' || fail "$1: no sing-box"
  if [ "$1" = podkop-engine-full ]; then
    sing-box version | grep -q podkop_full || fail "$1: tags"
  else
    sing-box version | grep -q podkop_full && fail "$1: tags"
  fi
  [ "$(uci -q get sing-box.main.memory_limit)" = 48MiB ] || fail "$1: /etc/config/sing-box lost the change"
  echo "now $1, config kept"
}

if command -v apk >/dev/null 2>&1; then
  apk update -q
  apk add -q --allow-untrusted /pkgs/podkop-engine_*.apk
  wget -q -O /tmp/pk/podkop.apk "$REL/podkop-$PODKOP_VERSION-r1.apk"
  apk add -q --allow-untrusted /tmp/pk/podkop.apk
  uci set sing-box.main.memory_limit=48MiB; uci commit sing-box
  apk add -q --allow-untrusted /pkgs/podkop-engine-full_*.apk '!podkop-engine' || fail "apk: to full"
  expect podkop-engine-full
  apk add -q --allow-untrusted /pkgs/podkop-engine_*.apk '!podkop-engine-full' || fail "apk: back"
  expect podkop-engine
  apk list -I 2>/dev/null | grep -E '^(podkop|sing-box)'
else
  opkg update >/dev/null
  opkg install /pkgs/podkop-engine_*.ipk >/dev/null
  wget -q -O /tmp/pk/podkop.ipk "$REL/podkop-v$PODKOP_VERSION-r1-all.ipk"
  opkg install /tmp/pk/podkop.ipk >/dev/null
  uci set sing-box.main.memory_limit=48MiB; uci commit sing-box
  opkg remove --force-depends podkop-engine >/dev/null && opkg install /pkgs/podkop-engine-full_*.ipk >/dev/null || fail "opkg: to full"
  expect podkop-engine-full
  opkg remove --force-depends podkop-engine-full >/dev/null && opkg install /pkgs/podkop-engine_*.ipk >/dev/null || fail "opkg: back"
  expect podkop-engine
  opkg list-installed | grep -E '^(podkop|sing-box)'
fi
echo PASS
