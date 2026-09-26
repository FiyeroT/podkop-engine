#!/bin/sh
# Сборка конфига sing-box настоящим кодом podkop в образе OpenWrt и `sing-box check` на нём.
apk update -q >/dev/null 2>&1; apk add -q jq coreutils-base64 >/dev/null 2>&1
mkdir -p /usr/lib/podkop /etc/sing-box /tmp/sing-box
cp /pk/files/usr/lib/*.sh /pk/files/usr/lib/*.jq /usr/lib/podkop/ 2>/dev/null
cp /t/podkop.uci /etc/config/podkop
# /usr/bin/podkop без финального диспетчера команд -> библиотека
n=$(grep -n '^case "\$1" in' /pk/files/usr/bin/podkop | tail -1 | cut -d: -f1)
head -n $((n-1)) /pk/files/usr/bin/podkop > /tmp/pk.sh
cat >> /tmp/pk.sh <<'X'
config_load "podkop"
sing_box_init_config
X
for sb in $SB_LIST; do
  cp /bin-sb/$sb /usr/bin/sing-box; rm -f /etc/sing-box/config.json
  sh /tmp/pk.sh >/tmp/pk.log 2>&1
  if [ -s /etc/sing-box/config.json ]; then
    echo "$sb: podkop config OK ($(jq -r '[.outbounds[].type]|join(",")' /etc/sing-box/config.json))"
  else
    echo "$sb: FAIL"; sing-box -c "$(ls -t /tmp/tmp.* 2>/dev/null | head -1)" check 2>&1 | tail -2; tail -3 /tmp/pk.log
  fi
done
