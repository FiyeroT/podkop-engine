#!/bin/sh
# Проверка пакета podkop-engine в образе OpenWrt (x86_64):
#   установка пакета -> установка podkop (зависимость sing-box закрывается PROVIDES) ->
#   `sing-box version` -> конфиг из podkop.uci кодом podkop -> `sing-box check`.
#
#   docker run --rm -v <каталог с пакетом>:/pkgs:ro -v <repo>/lab/podkop-check:/t:ro \
#     openwrt/rootfs:x86-64-24.10.8 sh /t/../pkg-test.sh        (ipk)
#     openwrt/rootfs:x86-64-25.12.5 ...                          (apk)
#
# PKG=podkop-engine-full checks the full package instead: every outbound type loads, and
# NaiveProxy on x86_64; podkop-engine must refuse those types with a message naming the
# full package.
set -eu
PKG=${PKG:-podkop-engine}
PODKOP_VERSION=${PODKOP_VERSION:-0.7.22}
REL=https://github.com/itdoginfo/podkop/releases/download/$PODKOP_VERSION
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p /var/lock /tmp/pk

if command -v apk >/dev/null 2>&1; then
  pkg=$(ls /pkgs/${PKG}_*.apk 2>/dev/null | head -1); [ -n "$pkg" ] || fail "no $PKG .apk in /pkgs"
  apk update -q
  apk add -q --allow-untrusted "$pkg" || fail "apk add $PKG"
  wget -q -O /tmp/pk/podkop.apk "$REL/podkop-$PODKOP_VERSION-r1.apk"
  apk add -q --allow-untrusted /tmp/pk/podkop.apk || fail "apk add podkop"
  apk list -I 2>/dev/null | grep -E '^(podkop|sing-box)' || true
else
  pkg=$(ls /pkgs/${PKG}_*.ipk 2>/dev/null | head -1); [ -n "$pkg" ] || fail "no $PKG .ipk in /pkgs"
  opkg update >/dev/null
  opkg install "$pkg" >/tmp/pk/opkg.log 2>&1 || { cat /tmp/pk/opkg.log; fail "opkg install $PKG"; }
  wget -q -O /tmp/pk/podkop.ipk "$REL/podkop-v$PODKOP_VERSION-r1-all.ipk"
  opkg install /tmp/pk/podkop.ipk >/tmp/pk/opkg.log 2>&1 || { cat /tmp/pk/opkg.log; fail "opkg install podkop"; }
  opkg list-installed | grep -E '^(podkop|sing-box)' || true
fi

v=$(sing-box version | head -1)
echo "$v"
echo "$v" | grep -qE -- '-pdk-r[0-9]+$' || fail "unexpected version string"
sing-box version | grep -q 'podkop_slim' || fail "podkop_slim tag missing"
sing-box api >/dev/null 2>&1 && fail "api CLI must be absent"
sing-box check -c /etc/sing-box/config.json || fail "the shipped config does not pass check"

# the outbounds only podkop-engine-full has (raw outbound configurations in podkop)
TLS='"server": "203.0.113.20", "server_port": 443, "tls": {"enabled": true, "server_name": "e.example.com"}'
for o in '"type": "vmess", "server": "203.0.113.20", "server_port": 443, "uuid": "6f1c9a0e-3b52-4c1e-9a55-2d4a1b0f7c11"' \
         '"type": "http", "server": "203.0.113.20", "server_port": 3128' \
         "\"type\": \"anytls\", $TLS, \"password\": \"p\"" \
         "\"type\": \"naive\", $TLS, \"username\": \"u\", \"password\": \"p\""; do
  printf '{"outbounds": [{"tag": "x", %s}]}\n' "$o" > /tmp/pk/one.json
  if [ "$PKG" = podkop-engine-full ]; then
    sing-box check -c /tmp/pk/one.json || fail "full: $o"
  else
    sing-box check -c /tmp/pk/one.json >/tmp/pk/check.log 2>&1 && fail "main accepts: $o"
    grep -q 'install podkop-engine-full' /tmp/pk/check.log || { cat /tmp/pk/check.log; fail "main: no hint for $o"; }
  fi
done
if [ "$PKG" = podkop-engine-full ]; then
  sing-box version | grep -q 'podkop_full' || fail "podkop_full tag missing"
  sing-box version | grep -q 'with_naive_outbound' || fail "NaiveProxy missing on x86_64"
else
  sing-box version | grep -q 'podkop_full' && fail "main has podkop_full"
fi
echo "$PKG: outbound types as expected"

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
