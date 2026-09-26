#!/usr/bin/env python3
"""Сравнение ClientHello, которые реально уходят в сеть от xray-клиента и от sing-box.

Для каждого отпечатка поднимает TCP-ловушку, запускает клиента (REALITY-outbound
смотрит в ловушку), дёргает его через SOCKS и разбирает первый TLS-record.
Сравнивает структуру (GREASE нормализован, порядок расширений Chrome — как множество).

  ./compare-hello.py bin/xray-26.9.9 bin/sing-box-1.14.2-patched-fp chrome firefox safari
"""
import json, os, socket, subprocess, sys, tempfile, threading, time

UUID = "6f1c9a0e-3b52-4c1e-9a55-2d4a1b0f7c11"
PUB = "TyK5Ml0SeZmyYFHYYN4VHaV19HMb2GcH3DSRabyxHmU"
SID = "0123456789abcdef"
TRAP, SOCKS = 18443, 11080
EXT = {0: "server_name", 5: "status_request", 10: "supported_groups", 11: "ec_point_formats",
       13: "signature_algorithms", 16: "alpn", 18: "sct", 23: "extended_master_secret",
       27: "compress_certificate", 28: "record_size_limit", 34: "delegated_credentials",
       35: "session_ticket", 41: "pre_shared_key", 43: "supported_versions", 45: "psk_key_exchange_modes",
       51: "key_share", 17513: "application_settings_old", 17613: "application_settings",
       65037: "encrypted_client_hello", 65281: "renegotiation_info", 21: "padding"}


def g(v):  # GREASE -> символ
    return "GREASE" if (v & 0x0F0F) == 0x0A0A and (v >> 8) == (v & 0xFF) else hex(v)


def u16(b, o):
    return int.from_bytes(b[o:o + 2], "big")


def parse(rec):
    hs = rec[5:]
    body = hs[4:]
    o = 2 + 32
    sid_len = body[o]; o += 1 + sid_len
    cs_len = u16(body, o); o += 2
    ciphers = [g(u16(body, o + i)) for i in range(0, cs_len, 2)]; o += cs_len
    o += 1 + body[o]
    ext_len = u16(body, o); o += 2
    end = o + ext_len
    exts, info = [], {}
    while o < end:
        t, ln = u16(body, o), u16(body, o + 2)
        d = body[o + 4:o + 4 + ln]; o += 4 + ln
        name = EXT.get(t, g(t))
        exts.append(name)
        if t == 10:
            info["groups"] = [g(u16(d, 2 + i)) for i in range(0, u16(d, 0), 2)]
        elif t == 13:
            info["sig_algs"] = [hex(u16(d, 2 + i)) for i in range(0, u16(d, 0), 2)]
        elif t == 51:
            ks, p = [], 2
            while p < len(d):
                grp, kl = u16(d, p), u16(d, p + 2)
                ks.append((g(grp), kl, d[p + 4:p + 4 + kl])); p += 4 + kl
            info["key_share"] = [(k[0], k[1]) for k in ks]
            hyb = [k for k in ks if k[0] == "0x11ec"]
            x = [k for k in ks if k[0] == "0x1d"]
            if hyb and x:
                info["x25519_reused_from_hybrid"] = hyb[0][2][-32:] == x[0][2]
        elif t == 43:
            info["versions"] = [g(u16(d, 1 + i)) for i in range(0, d[0], 2)]
        elif t == 27:
            info["cert_compression"] = [hex(u16(d, 1 + i)) for i in range(0, d[0], 2)]
        elif t == 28:
            info["record_size_limit"] = hex(u16(d, 0))
        elif t == 65037:
            info["ech_len"] = ln
        elif t == 34:
            info["delegated_credentials"] = [hex(u16(d, 2 + i)) for i in range(0, u16(d, 0), 2)]
        elif t == 16:
            info["alpn"] = ln
    info["session_id_len"] = sid_len
    return ciphers, exts, info


def capture(cmd, cfg):
    got = {}
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", TRAP)); srv.listen(1); srv.settimeout(10)

    def trap():
        try:
            c, _ = srv.accept(); c.settimeout(5)
            buf = b""
            while len(buf) < 5 or len(buf) < 5 + u16(buf, 3):
                chunk = c.recv(65536)
                if not chunk:
                    break
                buf += chunk
            got["rec"] = buf; c.close()
        except OSError:
            pass
    th = threading.Thread(target=trap); th.start()
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(cfg, f)
    p = subprocess.Popen(cmd + [f.name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.7)
    subprocess.run(["curl", "-s", "-m", "3", "-x", f"socks5h://127.0.0.1:{SOCKS}", "http://example.com/"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    th.join(); p.kill(); p.wait(); srv.close(); os.unlink(f.name)
    return got.get("rec")


def xray_cfg(fp):
    return {"log": {"loglevel": "none"},
            "inbounds": [{"listen": "127.0.0.1", "port": SOCKS, "protocol": "socks"}],
            "outbounds": [{"protocol": "vless",
                           "settings": {"vnext": [{"address": "127.0.0.1", "port": TRAP,
                                                   "users": [{"id": UUID, "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
                           "streamSettings": {"network": "raw", "security": "reality",
                                              "realitySettings": {"serverName": "reality.test", "fingerprint": fp,
                                                                  "password": PUB, "shortId": SID}}}]}


def sb_cfg(fp):
    return {"log": {"disabled": True},
            "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": SOCKS}],
            "outbounds": [{"type": "vless", "server": "127.0.0.1", "server_port": TRAP, "uuid": UUID,
                           "flow": "xtls-rprx-vision",
                           "tls": {"enabled": True, "server_name": "reality.test",
                                   "utls": {"enabled": True, "fingerprint": fp},
                                   "reality": {"enabled": True, "public_key": PUB, "short_id": SID}}}]}


def main():
    xray, sb, fps = sys.argv[1], sys.argv[2], sys.argv[3:]
    ok_all = True
    for fp in fps:
        a = capture([xray, "run", "-c"], xray_cfg(fp))
        b = capture([sb, "run", "-c"], sb_cfg(fp))
        if not a or not b:
            print(f"[{fp}] capture failed: xray={bool(a)} sing-box={bool(b)}"); ok_all = False; continue
        (ca, ea, ia), (cb, eb, ib) = parse(a), parse(b)
        shuffled = fp == "chrome"  # Chrome перемешивает порядок расширений
        same_ext = sorted(ea) == sorted(eb) if shuffled else ea == eb
        diffs = []
        if ca != cb: diffs.append(f"ciphers\n    xray: {ca}\n    sbox: {cb}")
        if not same_ext: diffs.append(f"extensions\n    xray: {ea}\n    sbox: {eb}")
        for k in sorted((set(ia) | set(ib)) - ({"ech_len"} if shuffled else set())):  # у Chrome длина GREASE-ECH случайна
            if ia.get(k) != ib.get(k):
                diffs.append(f"{k}\n    xray: {ia.get(k)}\n    sbox: {ib.get(k)}")
        print(f"[{fp}] {'IDENTICAL structure' if not diffs else 'DIFFERS'}"
              f"  (ext={len(ea)}{', order shuffled' if shuffled else ''}; key_share={ib.get('key_share')};"
              f" x25519 reused={ib.get('x25519_reused_from_hybrid')})")
        for d in diffs:
            print("  - " + d)
        ok_all &= not diffs
    sys.exit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
