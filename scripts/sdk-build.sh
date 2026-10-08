#!/bin/sh
# Сборка podkop-engine внутри образа openwrt/sdk для одной или нескольких веток sing-box.
# Фиды и хостовый Go готовятся один раз, затем ветки собираются по очереди.
#
#   docker run --rm -v <repo>:/src:ro -v <out>:/out [-v <dl-cache>:/builder/dl] \
#     openwrt/sdk:<target>-v<release> sh /src/scripts/sdk-build.sh [1.12 1.13 1.14]
#
# Без аргументов собирает все ветки из LINES в versions.env.
# Результат: /out/podkop-engine_<версия>-r<N>_openwrt_<pkgarch>.ipk (SDK 24.10) или .apk
# (SDK 25.12+), плюс /out/build-<ветка>.log.
#
# Each line builds podkop-engine and, when its patches have the tag podkop_full,
# podkop-engine-full: /out/podkop-engine-full_<version>-r<N>_openwrt_<pkgarch>.<ipk|apk>.
# NaiveProxy in podkop-engine-full is linked with lld (see the package Makefile): for the
# pkgarchs of naive.pkgarchs the script fetches the lld of Chromium's clang package, the
# toolchain cronet is built with (LLD_URL and LLD_SHA256 in versions.env, kept in dl/).
# Started as root (docker run --user root, as CI does), it first hands dl/ to buildbot.
set -eu
SRC=${SRC:-/src}
OUT=${OUT:-/out}

. "$SRC/versions.env"

log() { printf '\n=== %s\n' "$*"; }

if [ "$(id -u)" = 0 ]; then
  # the download cache restored by CI belongs to the runner: Go must add new modules to it
  [ -d /builder/dl ] && chown -R buildbot:buildbot /builder/dl
  exec runuser -u buildbot -- env HOME=/builder SRC="$SRC" OUT="$OUT" sh "$0" "$@"
fi

fetch_lld() {
  [ -n "${PODKOP_ENGINE_LLD:-}" ] && return 0
  f=dl/$(basename "$LLD_URL")
  if ! echo "$LLD_SHA256  $f" | sha256sum -c - >/dev/null 2>&1; then
    curl -fsSL --retry 6 --retry-all-errors --retry-delay 10 -o "$f" "$LLD_URL"
    echo "$LLD_SHA256  $f" | sha256sum -c - >/dev/null
  fi
  rm -rf /builder/podkop-engine-lld && mkdir -p /builder/podkop-engine-lld
  tar xJf "$f" -C /builder/podkop-engine-lld bin/lld bin/ld.lld
  PODKOP_ENGINE_LLD=/builder/podkop-engine-lld/bin/ld.lld; export PODKOP_ENGINE_LLD
  log "$("$PODKOP_ENGINE_LLD" --version | cut -d'(' -f1)for NaiveProxy"
}

cd /builder
[ $# -gt 0 ] || set -- $LINES

# 1. Фиды: base (метаданные ca-bundle и kmod-*) и packages, на коммитах этого SDK.
#    src-git-full base -> неглубокий src-git: история не нужна.
log "feeds"
grep -E '^src-git(-full)? (base|packages) ' feeds.conf.default | sed 's/^src-git-full /src-git /' > feeds.conf
cat feeds.conf
# git.openwrt.org refuses a connection now and then, and a feed that could not be cloned
# fails the update: ask again a few times
n=0
until ./scripts/feeds update base packages >/dev/null; do
  n=$((n + 1)); [ $n -lt 5 ] || { echo "feeds update failed $n times" >&2; exit 1; }
  echo "feeds update failed, once more in 20 s" >&2
  sleep 20
done

# 2. Go: штатный lang/golang заменяется закреплённым (versions.env) — в 24.10 штатный
#    Go 1.23 не собирает sing-box 1.13+, а одна версия Go на все сборки проще сопровождать.
log "lang/golang @ $GOLANG_FEED_COMMIT"
tmp=$(mktemp -d)
git -C "$tmp" init -q
git -C "$tmp" remote add origin "$GOLANG_FEED_REPO"
git -C "$tmp" sparse-checkout set lang/golang
n=0
until git -C "$tmp" fetch -q --depth 1 --filter=blob:none origin "$GOLANG_FEED_COMMIT"; do
  n=$((n + 1)); [ $n -lt 5 ] || { echo "fetch of lang/golang failed $n times" >&2; exit 1; }
  sleep 20
done
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
  full=; grep -qs podkop_full "$SRC/patches/v$LINE"/*.patch && full=1
  [ -n "$full" ] && echo 'CONFIG_PACKAGE_podkop-engine-full=m' >> .config
  make defconfig >/dev/null 2>&1
  pkgarch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' .config)
  naive=; [ -n "$full" ] && grep -qx "$pkgarch" package/podkop-engine/naive.pkgarchs && naive=1
  [ -n "$naive" ] && fetch_lld
  rm -rf bin/packages
  if make package/podkop-engine/compile -j"$(nproc)" V="${V:-s}" > "$OUT/build-$LINE.log" 2>&1; then
    # имена как у релизов sing-box: <пакет>_<версия>_openwrt_<pkgarch>.<ipk|apk>
    find bin/packages \( -name 'podkop-engine*.ipk' -o -name 'podkop-engine*.apk' \) | while read -r f; do
      arch=$(basename "$(dirname "$(dirname "$f")")")
      pkg=$(basename "$f" | sed -E 's/^(podkop-engine(-full)?)[-_].*/\1/')
      dst="$OUT/${pkg}_${SB_VERSION}-r${SB_RELEASE}_openwrt_${arch}.${f##*.}"
      cp "$f" "$dst"; ls -l "$dst"
    done
    # NaiveProxy must be in podkop-engine-full wherever naive.pkgarchs lists the target
    if [ -n "$naive" ]; then
      bin=$(find build_dir -path "*/podkop-engine-full/sing-box-$SB_VERSION/*/usr/bin/sing-box" -type f | head -1)
      if [ -n "$bin" ] && grep -ao -- '-tags=[a-z0-9_,]*' "$bin" | grep -q with_naive_outbound; then
        echo "NaiveProxy: in podkop-engine-full ($pkgarch)"
      else
        echo "NaiveProxy MISSING in podkop-engine-full ($pkgarch)"; status=1
      fi
    fi
  else
    echo "BUILD FAILED: $LINE (see build-$LINE.log)"; tail -30 "$OUT/build-$LINE.log"; status=1
  fi
done
exit $status
