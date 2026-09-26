# Установка на роутер (вручную, до появления фида)

Пакет ставит `/usr/bin/sing-box`, `/etc/init.d/sing-box`, `/etc/config/sing-box` — те же пути,
что пакет `sing-box` из OpenWrt, поэтому с ним он конфликтует и заменяет его.
Файл брать под свою архитектуру (`opkg print-architecture` / `apk --print-arch`).

## OpenWrt 24.10 и старше (opkg, .ipk)

```sh
opkg update
# если стоит sing-box из репозитория (podkop от него зависит — отсюда --force-depends):
opkg remove --force-depends sing-box sing-box-tiny 2>/dev/null
opkg install /tmp/podkop-engine_1.14.2-r1_<pkgarch>.ipk
service podkop restart
```

Без удаления opkg откажет: `The following packages conflict with podkop-engine: sing-box`.
После замены `opkg upgrade` фидовый sing-box обратно не предлагает.

## OpenWrt 25.12 и snapshot (apk, .apk)

```sh
apk update
apk add --allow-untrusted /tmp/podkop-engine-1.14.2-r1_<pkgarch>.apk
service podkop restart
```

apk заменяет установленный `sing-box` сам (одной транзакцией): оба пакета дают `sing-box`,
а файлы совпадают. `--allow-untrusted` нужен, пока пакеты не подписаны.
При установке из файла apk закрепляет в `/etc/apk/world` именно этот пакет, и `apk upgrade`
не возвращает фидовый sing-box, даже если тот новее.

## Откат на sing-box из репозитория

```sh
opkg remove --force-depends podkop-engine && opkg install sing-box      # opkg
apk add sing-box '!podkop-engine'                                        # apk: одной транзакцией
```

`apk del podkop-engine` отдельно не сработает: от него зависит podkop.

## Проверка

```sh
sing-box version     # sing-box version 1.14.2-pdk ... Tags: with_quic,with_utls,with_clash_api,podkop_slim,...
```
