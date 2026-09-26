#!/bin/sh
# Сборка podkop-engine внутри образа openwrt/sdk для одной или нескольких веток sing-box.
# Фиды и хостовый Go готовятся один раз, затем ветки собираются по очереди.
#
#   docker run --rm -v <repo>:/src:ro -v <out>:/out [-v <dl-cache>:/builder/dl] \
#     openwrt/sdk:<target>-v<release> sh /src/scripts/sdk-build.sh [1.12 1.13 1.14]
#
# Без аргументов собирает все ветки из LINES в versions.env.
# Результат: /out/podkop-engine_<версия>-r<N>_<pkgarch>.ipk (SDK 24.10) или
# /out/podkop-engine-<версия>-r<N>_<pkgarch>.apk (SDK 25.12+), плюс /out/build-<ветка>.log.
set -eu
SRC=${SRC:-/src}
OUT=${OUT:-/out}
cd /builder

. "$SRC/versions.env"
[ $# -gt 0 ] || set -- $LINES

log() { printf '\n=== %s\n' "$*"; }

# 1. Фиды: base (метаданные ca-bundle и kmod-*) и packages, на коммитах этого SDK.
#    src-git-full base -> неглубокий src-git: история не нужна.
log "feeds"
grep -E '^src-git(-full)? (base|packages) ' feeds.conf.default | sed 's/^src-git-full /src-git /' > feeds.conf
cat feeds.conf
./scripts/feeds update base packages >/dev/null

# 2. Go: штатный lang/golang заменяется закреплённым (versions.env) — в 24.10 штатный
#    Go 1.23 не собирает sing-box 1.13+, а одна версия Go на все сборки проще сопровождать.
log "lang/golang @ $GOLANG_FEED_COMMIT"
tmp=$(mktemp -d)
git -C "$tmp" init -q
git -C "$tmp" remote add origin "$GOLANG_FEED_REPO"
git -C "$tmp" sparse-checkout set lang/golang
git -C "$tmp" fetch -q --depth 1 --filter=blob:none origin "$GOLANG_FEED_COMMIT"
git -C "$tmp" checkout -q FETCH_HEAD
rm -rf feeds/packages/lang/golang
cp -a "$tmp/lang/golang" feeds/packages/lang/golang
rm -rf "$tmp"
./scripts/feeds update -i packages >/dev/null
./scripts/feeds install -p packages golang >/dev/null
./scripts/feeds install -p base ca-certificates >/dev/null

mkdir -p "$OUT"
status=0
for LINE in "$@"; do
  key=$(echo "$LINE" | tr . _)
  eval "SB_VERSION=\${SB_${key}_VERSION:-}; SB_HASH=\${SB_${key}_HASH:-}; SB_RELEASE=\${SB_${key}_RELEASE:-}"
  if [ -z "$SB_VERSION" ] || [ ! -d "$SRC/patches/v$LINE" ]; then
    echo "unknown line $LINE (versions.env / patches)" >&2; status=1; continue
  fi

  # 3. Пакет: Makefile, файлы, патчи ветки и версия.
  log "podkop-engine $SB_VERSION-r$SB_RELEASE (patches v$LINE)"
  rm -rf package/podkop-engine
  cp -a "$SRC/openwrt/podkop-engine" package/podkop-engine
  mkdir -p package/podkop-engine/patches
  cp "$SRC/patches/v$LINE"/*.patch package/podkop-engine/patches/
  cat > package/podkop-engine/version.mk <<EOF
SB_VERSION:=$SB_VERSION
SB_HASH:=$SB_HASH
SB_RELEASE:=$SB_RELEASE
EOF

  # 4. Сборка.
  rm -f .config
  make defconfig >/dev/null 2>&1
  echo 'CONFIG_PACKAGE_podkop-engine=m' >> .config
  make defconfig >/dev/null 2>&1
  rm -rf bin/packages
  if make package/podkop-engine/compile -j"$(nproc)" V="${V:-s}" > "$OUT/build-$LINE.log" 2>&1; then
    # ipk уже содержит pkgarch в имени; apk — нет, а в релизе все архитектуры лежат рядом
    find bin/packages \( -name 'podkop-engine*.ipk' -o -name 'podkop-engine*.apk' \) | while read -r f; do
      case $f in
        *.apk) arch=$(basename "$(dirname "$(dirname "$f")")"); dst="$OUT/$(basename "${f%.apk}")_$arch.apk";;
        *)     dst="$OUT/$(basename "$f")";;
      esac
      cp "$f" "$dst"; ls -l "$dst"
    done
  else
    echo "BUILD FAILED: $LINE (see build-$LINE.log)"; tail -30 "$OUT/build-$LINE.log"; status=1
  fi
done
exit $status
