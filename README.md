# podkop-engine

Неофициальная сборка [sing-box](https://github.com/SagerNet/sing-box) для
[podkop](https://github.com/itdoginfo/podkop) на OpenWrt. **Проект не связан с sing-box и его
авторами**; пакет называется иначе, потому что лицензия sing-box запрещает производным работам
использовать его имя. Бинарь по-прежнему устанавливается как `/usr/bin/sing-box`, пакет объявляет
`PROVIDES: sing-box`, поэтому зависимость podkop от `sing-box` выполняется.

Распространяется на условиях GPL-3.0-or-later (см. `LICENSE`; исходная лицензия sing-box —
`LICENSE.sing-box`). Упаковка основана на `net/sing-box` из openwrt/packages.

## Чем отличается от sing-box из репозитория OpenWrt

| | |
|---|---|
| REALITY | работает с Xray-core 26.7+ и 26.9+ (как Xray-клиент 26.9.9): ClientHello несёт X25519MLKEM768, клиент заявляет версию 26.3.27 |
| отпечатки uTLS | `firefox` = Firefox 148, `safari` = Safari 26.3 (как в Xray), `random` выбирает только из chrome/firefox/safari |
| состав | только то, что нужно podkop: `with_quic` (Hysteria2, TUIC), `with_utls` (REALITY, `fp=`), `with_clash_api` (дашборд LuCI, YACD) |
| 1.14: `podkop_slim` | нет CLI `sing-box api`, API-сервиса и протокола snell (~6 МБ) |
| старт без списков (1.13, 1.14) | если remote rule-set не скачался при старте (WAN ещё не поднялся, неверное время, первый узел urltest мёртв), sing-box стартует с пустым списком и докачивает его (5, 10, 20 с, дальше раз в 30 с), а не падает; после докачки один раз запускает `podkop list_update` |
| urltest (1.13) | перепроверяет узлы при смене сетевого интерфейса (как 1.14), а не через 3 минуты |
| зависимости | без `kmod-tun` и `kmod-inet-diag` |
| версия | `sing-box version` → `1.14.2-pdk` |

Чего нет по сравнению с полным sing-box: TUN (gvisor), WireGuard/Tailscale внутри sing-box
(WireGuard/AmneziaWG в podkop подключаются интерфейсом OpenWrt — это работает), DHCP-DNS, ACME и т.п.

**Совместимость с серверами.** Патченный клиент ведёт себя как Xray-клиент 26.9.9. Единственный
случай, где обычный sing-box работает, а этот — нет: Xray-сервер ≤ 25.4.30 и сайт-прикрытие,
выбирающий X25519MLKEM768 (большинство крупных зарубежных сайтов). Лечится обновлением Xray на сервере.

## Ветки и форматы

Собираются последние теги веток 1.12, 1.13, 1.14 (`versions.env`) под все архитектуры, для
которых sing-box есть в официальном репозитории OpenWrt:

- `.ipk` (opkg, OpenWrt 24.10 и старше) — SDK 24.10;
- `.apk` (apk, OpenWrt 25.12 и snapshot) — SDK 25.12.

Релизы — по одному на ветку (тег `v<версия sing-box>-r<ревизия>`, например `v1.14.2-r1`), файлы
названы как у sing-box: `podkop-engine_1.14.2-r1_openwrt_<pkgarch>.ipk` / `.apk`, плюс `SHA256SUMS`.

Go во всех сборках один — закреплённый `lang/golang` из openwrt/packages (Go 1.26.x).

## Устройство

```
patches/v1.12, v1.13, v1.14   патчи к тегу upstream (git format-patch)
  0001  reality: X25519MLKEM768 и версия клиента 26.3.27
  0002  utls: firefox -> Firefox 148, safari -> Safari 26.3
  0003  (1.14) тег podkop_slim: без snell и API-сервиса
  0003 (1.13) / 0004 (1.14)  rule-set: старт с пустым списком, докачка, хук
                             SING_BOX_RULESET_RECOVERED_HOOK
  0004  (1.13) urltest: перепроверка при смене интерфейса
openwrt/podkop-engine/        Makefile пакета (+ init-скрипт и UCI-конфиг из net/sing-box);
                              init передаёт sing-box хук files/lists-recovered, если стоит podkop
versions.env                  версии upstream, sha256 архивов, ревизии пакета, Go, релизы SDK
scripts/gen-matrix.py         pkgarch -> образ openwrt/sdk
scripts/sdk-build.sh          сборка в образе SDK (одна или несколько веток)
lab/                          стенд: Xray-сервер/клиент + sing-box, проверка пакета в OpenWrt
.github/workflows/build.yml   ручной запуск: сборка -> проверка -> черновик релиза
```

## Локальная сборка одной архитектуры

```sh
docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" \
  openwrt/sdk:x86-64-v24.10.8 sh /src/scripts/sdk-build.sh 1.14
```

## Проверки

```sh
# пакет в OpenWrt + podkop + `sing-box check` на конфиге, собранном кодом podkop
docker run --rm -v "$PWD/out:/pkgs:ro" -v "$PWD/lab/podkop-check:/t:ro" -v "$PWD/lab:/lab:ro" \
  openwrt/rootfs:x86-64-24.10.8 sh /lab/pkg-test.sh
# стенд REALITY: Xray 24.11 … 26.9 × прикрытие с/без MLKEM, сверка с ожиданием
lab/fetch-bins.sh out lab/bin && lab/gate.sh lab/bin
```

Выпуск новой версии — `docs/RELEASE.md`, установка на роутер вручную — `docs/INSTALL.md`.

## Старт, когда списки не скачиваются

Обычный sing-box при недоступном remote rule-set завершается с `FATAL ... initial rule-set`;
procd после нескольких перезапусков сдаётся, и роутер остаётся без прокси и без DNS
(dnsmasq podkop уже переключил на sing-box). podkop-engine 1.13/1.14 в этом случае стартует с
пустым списком и докачивает его сам. Когда докачка удалась (путь до списков заработал), sing-box
один раз выполняет команду из `SING_BOX_RULESET_RECOVERED_HOOK`; init-скрипт пакета задаёт её,
только если установлен podkop: `/usr/libexec/podkop-engine/lists-recovered` дожидается
стартового `list_update` podkop (если тот ещё идёт) и запускает `podkop list_update` — так
догружаются списки, которые podkop качает сам (подсети в nft, текстовые списки). podkop при этом
не меняется; sing-box не перезапускается. После перезапуска sing-box списки берутся из cache.db,
хук не срабатывает.
