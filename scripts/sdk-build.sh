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
# NaiveProxy in podkop-engine-full needs lld (see the package Makefile): started as root
# (docker run --user root), the script installs lld $LLD_VERSION from apt.llvm.org and goes
# on as buildbot; started as buildbot, it builds podkop-engine-full without NaiveProxy
# unless lld is already there.
set -eu
SRC=${SRC:-/src}
OUT=${OUT:-/out}

. "$SRC/versions.env"

log() { printf '\n=== %s\n' "$*"; }

if [ "$(id -u)" = 0 ]; then
  # PKGARCH (set by CI) of a target without NaiveProxy needs no lld
  if [ -z "${PKGARCH:-}" ] || grep -qx "$PKGARCH" "$SRC/openwrt/podkop-engine/naive.pkgarchs"; then
    log "lld $LLD_VERSION (apt.llvm.org)"
    . /etc/os-release
    curl -fsSL --retry 6 --retry-all-errors --retry-delay 10 https://apt.llvm.org/llvm-snapshot.gpg.key > /etc/apt/trusted.gpg.d/apt.llvm.org.asc
    echo "deb http://apt.llvm.org/$VERSION_CODENAME/ llvm-toolchain-$VERSION_CODENAME-$LLD_VERSION main" > /etc/apt/sources.list.d/llvm.list
    apt-get -o Acquire::Retries=6 update -qq >/dev/null
    apt-get -o Acquire::Retries=6 install -y -qq --no-install-recommends "lld-$LLD_VERSION" >/dev/null
    "/usr/lib/llvm-$LLD_VERSION/bin/ld.lld" --version
  fi
  # the download cache restored by CI belongs to the runner: Go must add new modules to it
  [ -d /builder/dl ] && chown -R buildbot:buildbot /builder/dl
  exec runuser -u buildbot -- env HOME=/builder SRC="$SRC" OUT="$OUT" sh "$0" "$@"
fi

cd /builder
[ $# -gt 0 ] || set -- $LINES

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
  full=; grep -qs podkop_full "$SRC/patches/v$LINE"/*.patch && full=1
  [ -n "$full" ] && echo 'CONFIG_PACKAGE_podkop-engine-full=m' >> .config
  make defconfig >/dev/null 2>&1
  rm -rf bin/packages
  if make package/podkop-engine/compile -j"$(nproc)" V="${V:-s}" > "$OUT/build-$LINE.log" 2>&1; then
    # имена как у релизов sing-box: <пакет>_<версия>_openwrt_<pkgarch>.<ipk|apk>
    find bin/packages \( -name 'podkop-engine*.ipk' -o -name 'podkop-engine*.apk' \) | while read -r f; do
      arch=$(basename "$(dirname "$(dirname "$f")")")
      pkg=$(basename "$f" | sed -E 's/^(podkop-engine(-full)?)[-_].*/\1/')
      dst="$OUT/${pkg}_${SB_VERSION}-r${SB_RELEASE}_openwrt_${arch}.${f##*.}"
      cp "$f" "$dst"; ls -l "$dst"
    done
    # NaiveProxy must be in podkop-engine-full wherever cronet exists and lld was found
    pkgarch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"$/\1/p' .config)
    lld=$(ls /usr/lib/llvm-19/bin/ld.lld /usr/lib/llvm-[2-9][0-9]/bin/ld.lld 2>/dev/null | tail -1)
    if [ -n "$full" ] && grep -qx "$pkgarch" package/podkop-engine/naive.pkgarchs; then
      bin=$(find build_dir -path "*/podkop-engine-full/sing-box-$SB_VERSION/*/usr/bin/sing-box" -type f | head -1)
      if [ -n "$bin" ] && grep -ao -- '-tags=[a-z0-9_,]*' "$bin" | grep -q with_naive_outbound; then
        echo "NaiveProxy: in podkop-engine-full ($pkgarch, $lld)"
      elif [ -n "$lld" ]; then
        echo "NaiveProxy MISSING in podkop-engine-full ($pkgarch) although $lld is there"; status=1
      else
        echo "NaiveProxy: not built for $pkgarch, no lld 19+ (run as root to install it)"
      fi
    fi
  else
    echo "BUILD FAILED: $LINE (see build-$LINE.log)"; tail -30 "$OUT/build-$LINE.log"; status=1
  fi
done
exit $status
