#!/bin/sh
# Проверка пакета podkop-engine в образе OpenWrt (x86_64):
#   установка пакета -> установка podkop (зависимость sing-box закрывается PROVIDES) ->
#   `sing-box version` -> конфиг из podkop.uci кодом podkop -> `sing-box check`.
#
#   docker run --rm -v <каталог с пакетом>:/pkgs:ro -v <repo>/lab/podkop-check:/t:ro \
#     openwrt/rootfs:x86-64-24.10.8 sh /t/../pkg-test.sh        (ipk)
#     openwrt/rootfs:x86-64-25.12.5 ...                          (apk)
set -eu
PODKOP_VERSION=${PODKOP_VERSION:-0.7.22}
REL=https://github.com/itdoginfo/podkop/releases/download/$PODKOP_VERSION
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p /var/lock /tmp/pk

if command -v apk >/dev/null 2>&1; then
  pkg=$(ls /pkgs/podkop-engine_*.apk 2>/dev/null | head -1); [ -n "$pkg" ] || fail "no .apk in /pkgs"
  apk update -q
  apk add -q --allow-untrusted "$pkg" || fail "apk add podkop-engine"
  wget -q -O /tmp/pk/podkop.apk "$REL/podkop-$PODKOP_VERSION-r1.apk"
  apk add -q --allow-untrusted /tmp/pk/podkop.apk || fail "apk add podkop"
  apk list -I 2>/dev/null | grep -E '^(podkop|sing-box)' || true
else
  pkg=$(ls /pkgs/podkop-engine_*.ipk 2>/dev/null | head -1); [ -n "$pkg" ] || fail "no .ipk in /pkgs"
  opkg update >/dev/null
  opkg install "$pkg" >/tmp/pk/opkg.log 2>&1 || { cat /tmp/pk/opkg.log; fail "opkg install podkop-engine"; }
  wget -q -O /tmp/pk/podkop.ipk "$REL/podkop-v$PODKOP_VERSION-r1-all.ipk"
  opkg install /tmp/pk/podkop.ipk >/tmp/pk/opkg.log 2>&1 || { cat /tmp/pk/opkg.log; fail "opkg install podkop"; }
  opkg list-installed | grep -E '^(podkop|sing-box)' || true
fi

v=$(sing-box version | head -1)
echo "$v"
echo "$v" | grep -q -- '-pdk$' || fail "unexpected version string"
sing-box version | grep -q 'podkop_slim' || fail "podkop_slim tag missing"
sing-box api >/dev/null 2>&1 && fail "api CLI must be absent"

# конфиг podkop: настоящий /usr/bin/podkop без диспетчера команд -> библиотека
cp /t/podkop.uci /etc/config/podkop
mkdir -p /etc/sing-box /tmp/sing-box
n=$(grep -n '^case "\$1" in' /usr/bin/podkop | tail -1 | cut -d: -f1)
head -n $((n-1)) /usr/bin/podkop > /tmp/pk/lib.sh
printf 'config_load "podkop"\nsing_box_init_config\n' >> /tmp/pk/lib.sh
rm -f /etc/sing-box/config.json
sh /tmp/pk/lib.sh >/tmp/pk/podkop.log 2>&1 || true
[ -s /etc/sing-box/config.json ] || { tail -5 /tmp/pk/podkop.log; fail "podkop config not generated/checked"; }
echo "podkop config OK: $(jq -r '[.outbounds[].type]|join(",")' /etc/sing-box/config.json)"
echo PASS
