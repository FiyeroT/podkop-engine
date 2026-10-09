# Установка на роутер (вручную, до появления фида)

Пакет ставит `/usr/bin/sing-box`, `/etc/init.d/sing-box`, `/etc/config/sing-box` — те же пути,
что пакет `sing-box` из OpenWrt, поэтому с ним он конфликтует и заменяет его.
Файл брать из релиза нужной версии (https://github.com/FiyeroT/podkop-engine/releases) под свою
архитектуру (`opkg print-architecture` / `apk --print-arch`), например
`podkop-engine_1.14.2-r13_openwrt_aarch64_cortex-a53.ipk`.

С r9 (1.13, 1.14) пакетов два, ставится один: `podkop-engine` — протоколы, которые использует
podkop, и TUIC; `podkop-engine-full` — плюс все остальные выходы для «Outbound Config» (http,
vmess, snell, tor, ssh, shadowtls, anytls, hysteria, NaiveProxy). Команды ниже одинаковы для
обоих, меняется только имя файла, а в командах отката — имя пакета (`podkop-engine-full`
вместо `podkop-engine`).

## OpenWrt 24.10 и старше (opkg, .ipk)

```sh
opkg update
# если стоит sing-box из репозитория (podkop от него зависит — отсюда --force-depends):
opkg remove --force-depends sing-box sing-box-tiny 2>/dev/null
opkg install /tmp/podkop-engine_<версия>_openwrt_<pkgarch>.ipk
service podkop restart
```

Без удаления opkg откажет: `The following packages conflict with podkop-engine: sing-box`.
После замены `opkg upgrade` фидовый sing-box обратно не предлагает.

## OpenWrt 25.12 и snapshot (apk, .apk)

```sh
apk update
apk add --allow-untrusted /tmp/podkop-engine_<версия>_openwrt_<pkgarch>.apk
service podkop restart
```

apk заменяет установленный `sing-box` сам (одной транзакцией): оба пакета дают `sing-box`,
а файлы совпадают. `--allow-untrusted` нужен, пока пакеты не подписаны.
При установке из файла apk закрепляет в `/etc/apk/world` именно этот пакет, и `apk upgrade`
не возвращает фидовый sing-box, даже если тот новее.

## Переход между podkop-engine и podkop-engine-full

```sh
opkg remove --force-depends podkop-engine && opkg install /tmp/podkop-engine-full_<версия>_openwrt_<pkgarch>.ipk   # opkg
apk add --allow-untrusted /tmp/podkop-engine-full_<версия>_openwrt_<pkgarch>.apk '!podkop-engine'                # apk
service podkop restart
```

Обратно — то же с именами наоборот. `/etc/config/sing-box` сохраняется.

## Откат на sing-box из репозитория

```sh
# opkg: сначала остановить podkop и скачать пакет, потом удалять
service podkop stop && opkg update && cd /tmp && opkg download sing-box && opkg remove --force-depends podkop-engine && opkg install /tmp/sing-box_*.ipk; service podkop start
# apk: одной транзакцией
apk add sing-box '!podkop-engine'
```

На opkg порядок важен. Пока podkop работает, все DNS-запросы роутера идут в sing-box: если
сначала удалить podkop-engine, роутер не сможет разрешить имя репозитория и скачать пакет, а
сеть останется без DNS. Если это уже случилось, DNS возвращает `service podkop stop`. После
установки podkop может подниматься до минуты.

`apk del podkop-engine` отдельно не сработает: от него зависит podkop.

## Проверка

```sh
sing-box version     # sing-box version 1.14.2-pdk-r13 ... Tags: with_quic,with_utls,with_clash_api,podkop_slim,...
```
