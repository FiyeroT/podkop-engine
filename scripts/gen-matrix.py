#!/usr/bin/env python3
"""Матрица сборки: какие pkgarch собирать и в каком образе openwrt/sdk.

Правило: собираем ровно те архитектуры, где в официальном репозитории OpenWrt есть sing-box.
ipk — в SDK SDK_IPK_RELEASE, apk — в SDK SDK_APK_RELEASE. Snapshot отдельно не собираем:
apk из 25.12 ставится и туда, а лишние каталоги pkgarch в snapshot (mips_4kec,
riscv64_riscv64) — остатки старых сборок (sing-box 1.11), их не собирает ни один target.

SDK выпускается под target/subtarget, поэтому для каждой pkgarch берётся первый target
(по алфавиту), у которого arch_packages совпадает и есть образ openwrt/sdk.

  scripts/gen-matrix.py [--format ipk|apk|all] > matrix.json
"""
import argparse
import json
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

DL = "https://downloads.openwrt.org"
HUB = "https://hub.docker.com/v2/repositories/openwrt/sdk/tags/"


def load_env(path):
    env = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r'^([A-Z0-9_]+)="?([^"#]*)"?', line.strip())
        if m:
            env[m.group(1)] = m.group(2).strip()
    return env


def get(url, tries=3):
    for i in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return r.read().decode()
        except Exception:
            if i == tries - 1:
                raise


def subdirs(url):
    return sorted(set(re.findall(r'href="([a-z0-9_.-]+)/"', get(url))) - {"..", "."})


def base(release):
    return f"{DL}/snapshots" if release == "SNAPSHOT" else f"{DL}/releases/{release}"


def image_tag(release, target, subtarget):
    suffix = "SNAPSHOT" if release == "SNAPSHOT" else f"v{release}"
    return f"{target}-{subtarget}-{suffix}"


def image_exists(tag):
    try:
        urllib.request.urlopen(HUB + tag, timeout=30)
        return True
    except Exception:
        return False


def pkgarch_targets(release):
    """pkgarch -> [(target, subtarget)], по profiles.json каждого subtarget."""
    root = base(release) + "/targets"
    pairs = [(t, s) for t in subdirs(root + "/") for s in subdirs(f"{root}/{t}/")]

    def arch(pair):
        # profiles.json есть не у всех target (например, malta): тогда берём
        # архитектуру из индекса пакетов target'а (ipk: Packages, apk: index.json)
        t, s = pair
        d = f"{root}/{t}/{s}"
        try:
            return pair, json.loads(get(f"{d}/profiles.json"))["arch_packages"]
        except Exception:
            pass
        try:
            return pair, json.loads(get(f"{d}/packages/index.json"))["architecture"]
        except Exception:
            pass
        try:
            m = re.search(r"^Architecture: (\S+)", get(f"{d}/packages/Packages"), re.M)
            return pair, m.group(1) if m else None
        except Exception:
            return pair, None

    out = {}
    with ThreadPoolExecutor(16) as ex:
        for pair, a in ex.map(arch, pairs):
            if a:
                out.setdefault(a, []).append(pair)
    return {a: sorted(v) for a, v in out.items()}


def singbox_arches(release):
    root = base(release) + "/packages"

    def has(a):
        return a, 'href="sing-box' in get(f"{root}/{a}/packages/")

    with ThreadPoolExecutor(16) as ex:
        return {a for a, ok in ex.map(has, subdirs(root + "/")) if ok}


def pick(release, arches):
    targets = pkgarch_targets(release)
    rows = []
    for a in sorted(arches):
        for t, s in targets.get(a, []):
            tag = image_tag(release, t, s)
            if image_exists(tag):
                rows.append({"pkgarch": a, "release": release, "target": f"{t}/{s}", "image": f"openwrt/sdk:{tag}"})
                break
        else:
            print(f"warning: no SDK image for {a} in {release}", file=sys.stderr)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=["ipk", "apk", "all"], default="all")
    ap.add_argument("--env", default="versions.env")
    ap.add_argument("--only", help="comma-separated pkgarch filter (for test runs)")
    args = ap.parse_args()
    env = load_env(args.env)
    only = set(args.only.split(",")) if args.only else None

    matrix = []
    if args.format in ("ipk", "all"):
        rel = env["SDK_IPK_RELEASE"]
        arches = singbox_arches(rel)
        matrix += [dict(r, format="ipk") for r in pick(rel, arches & only if only else arches)]
    if args.format in ("apk", "all"):
        rel = env["SDK_APK_RELEASE"]
        arches = singbox_arches(rel)
        matrix += [dict(r, format="apk") for r in pick(rel, arches & only if only else arches)]
    json.dump({"include": matrix}, sys.stdout, indent=1)
    print(f"{len(matrix)} jobs", file=sys.stderr)


if __name__ == "__main__":
    main()
