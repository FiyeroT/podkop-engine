#!/bin/sh
# Черновики релизов GitHub: по одному на ветку sing-box (тег v<версия>-r<N>), в каждом —
# .ipk и .apk всех архитектур, SHA256SUMS и описание. Существующий релиз не перезаписывается:
# опубликованные файлы не должны меняться, для пересборки поднимите SB_<ветка>_RELEASE.
#   GH_REPO=owner/repo scripts/release.sh <каталог с пакетами> [ветки...]
#   DRY_RUN=1 — ничего не создавать, показать описание и список файлов.
# Последняя ветка из LINES помечается как Latest.
set -eu
DIST=${1:?dir with packages}; shift
. ./versions.env
[ $# -gt 0 ] || set -- $LINES
newest=$(echo $LINES | tr ' ' '\n' | sort -V | tail -1)
repo=${GH_REPO:?GH_REPO=owner/repo}
url="https://github.com/$repo/releases/download"

for LINE in "$@"; do
  key=$(echo "$LINE" | tr . _)
  v=; r=; eval "v=\${SB_${key}_VERSION}; r=\${SB_${key}_RELEASE}"
  tag="v$v-r$r"
  if [ -z "${DRY_RUN:-}" ] && gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
    echo "release $tag already exists: bump SB_${key}_RELEASE in versions.env to publish a rebuild" >&2
    exit 1
  fi
  dir=$(mktemp -d)
  cp "$DIST"/podkop-engine_"$v"-r"$r"_openwrt_*.ipk "$DIST"/podkop-engine_"$v"-r"$r"_openwrt_*.apk "$dir"/
  (cd "$dir" && sha256sum -- *.ipk *.apk > SHA256SUMS)
  n_ipk=$(ls "$dir"/*.ipk | wc -l); n_apk=$(ls "$dir"/*.apk | wc -l)
  arches=$(ls "$dir"/*.ipk "$dir"/*.apk | sed 's/.*_openwrt_\(.*\)\.[ai]pk$/\1/' | sort -u | tr '\n' ' ')
  patches=$(for pf in "patches/v$LINE"/*.patch; do printf -- '- `%s` %s\n' "$(basename "$pf" | cut -c1-4)" "$(awk '/^Subject: /{s=$0; while ((getline l) > 0 && l ~ /^ /) s = s l; sub(/^Subject: \[PATCH[^]]*\] /, "", s); print s; exit}' "$pf")"; done)
  f=podkop-engine_${v}-r${r}_openwrt
  cat > "$dir/NOTES.md" <<EOF
sing-box **$v** для podkop на OpenWrt, ревизия пакета **r$r**. Неофициальная сборка, не связана с проектом sing-box.

Патчи к \`v$v\`:
$patches

Теги сборки: \`with_quic,with_utls,with_clash_api,podkop_slim\`. Go $GO_VERSION. \`sing-box version\` → \`$v-pdk-r$r\`.

**Установка** (\`<pkgarch>\` — \`opkg print-architecture\` / \`apk --print-arch\`; подробнее — [docs/INSTALL.md](https://github.com/$repo/blob/main/docs/INSTALL.md)):

OpenWrt 24.10 и старше (opkg):
\`\`\`sh
wget -O /tmp/pe.ipk $url/$tag/${f}_<pkgarch>.ipk
opkg remove --force-depends sing-box sing-box-tiny 2>/dev/null; opkg install /tmp/pe.ipk
\`\`\`
OpenWrt 25.12 и snapshot (apk):
\`\`\`sh
wget -O /tmp/pe.apk $url/$tag/${f}_<pkgarch>.apk
apk add --allow-untrusted /tmp/pe.apk
\`\`\`

Архитектуры ($n_ipk ipk, $n_apk apk): $arches

Совместимость: как Xray-клиент 26.9.9 (Xray-сервер 25.5.16+; с 24.x–25.4 — только если сайт-прикрытие не выбирает X25519MLKEM768).
EOF
  latest=--latest=false; [ "$LINE" = "$newest" ] && latest=--latest
  if [ -n "${DRY_RUN:-}" ]; then
    echo "### DRY_RUN: $tag $latest"; cat "$dir/NOTES.md"; ls "$dir"; rm -rf "$dir"; continue
  fi
  gh release create "$tag" -R "$repo" --draft $latest --title "podkop-engine $v-r$r" \
    --notes-file "$dir/NOTES.md" "$dir"/*.ipk "$dir"/*.apk "$dir/SHA256SUMS"
  echo "draft $tag: $n_ipk ipk + $n_apk apk"
  rm -rf "$dir"
done
