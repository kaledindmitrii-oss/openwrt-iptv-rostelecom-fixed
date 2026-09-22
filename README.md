# OpenWrt IPTV Rostelecom — Fixed

Независимый исправленный аналог проекта `v1rtuozz/openwrt-iptv-rostelecom`.

**Этот проект НЕ является частью Universal OpenWrt.**

## Что исправлено

- Нет захардкоженного MAC-адреса WAN.
- Скрипт не заменяет целиком `/etc/config/network`, `firewall`, `dhcp`, `igmpproxy`.
- Создаются только собственные UCI-секции с префиксом `rt_iptv_*`.
- Существующая WAN-конфигурация не меняется без явного согласия пользователя.
- Нет обязательной загрузки конфигов с GitHub во время установки.
- Поддерживаются `opkg` для старых OpenWrt и `apk` для OpenWrt 25.12+.
- IPTV-порт выбирается по фактическому интерфейсу `/sys/class/net`.
- Перед установкой создаётся отдельный backup.
- Есть `status`, `restore`, `uninstall`.
- Региональные multicast source IP можно добавлять командой `add-altnet`.
- Firewall использует отдельные зоны `iptv` и `iptv_lan`, а не предполагает, что имя interface является zone.
- Встроена проверка UCI-конфигурации перед применением.
- VLAN/bridge WAN топологии не угадываются автоматически: скрипт предупреждает об этом, чтобы не сломать сеть.

## Совместимость

Проект ориентирован на OpenWrt 23.05, 24.10 и 25.12+.

На 22 сентября 2026 года актуальная стабильная ветка OpenWrt — 25.12; последняя версия — 25.12.5. В OpenWrt 25.12 пакетный менеджер сменился с `opkg` на `apk`.

## Установка

Скопируйте `iptv-manager.sh` на роутер:

```sh
scp iptv-manager.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1
chmod +x /tmp/iptv-manager.sh
/tmp/iptv-manager.sh install
```

Либо:

```sh
sh /tmp/iptv-manager.sh
```

Без аргумента выполняется `install`.

Скрипт:

1. определит OpenWrt;
2. проверит/установит `igmpproxy`;
3. покажет доступные интерфейсы;
4. попросит выбрать физический порт для IPTV;
5. сохранит backup;
6. создаст отдельный IPTV bridge;
7. создаст DHCP для IPTV приставки;
8. создаст firewall-зоны и forwarding;
9. настроит IGMP proxy;
10. перезапустит нужные службы.

## Важное ограничение

Это решение рассчитано на классический **multicast IPTV + IGMP proxy**.

Ростелеком может использовать разные схемы по регионам и доступам. Если IPTV приходит через отдельный VLAN, нельзя безопасно угадать VLAN ID автоматически. В таком случае сначала нужно определить VLAN/портовую схему конкретного подключения.

## Если Wink показывает 2-9 / Multicast unavailable

Посмотрите логи:

```sh
logread -f | grep -i igmp
```

Если в логе появляется адрес multicast source, добавьте его:

```sh
/tmp/iptv-manager.sh add-altnet 212.12.12.236
```

Проверить конфигурацию:

```sh
/tmp/iptv-manager.sh status
```

## Откат

Перед установкой сохраняется backup в:

```text
/root/iptv-rostelecom-backups/
```

Полный откат к последнему backup:

```sh
/tmp/iptv-manager.sh restore
```

Удаление только конфигурации проекта:

```sh
/tmp/iptv-manager.sh uninstall
```

`uninstall` не создаёт новый backup поверх pre-install backup.

## Архитектура

```text
Ростелеком multicast
        |
     WAN L2
        |
   rt_iptv / igmpproxy
        |
  br-rt-iptv
        |
 IPTV Ethernet port
        |
   Wink / приставка
```

Основные UCI-секции:

- `network.rt_iptv`
- `network.rt_iptv_lan`
- `network.rt_iptv_dev`
- `dhcp.rt_iptv_dhcp`
- `firewall.rt_iptv_*`
- `igmpproxy.rt_iptv_*`

## Что НЕ делает проект

- не меняет Universal OpenWrt;
- не прошивает роутер;
- не угадывает VLAN Ростелекома;
- не заменяет WAN-конфигурацию без подтверждения;
- не обещает работу IPTV в регионах, где provider topology отличается;
- не является официальной конфигурацией Ростелекома.

## Проверка перед реальным использованием

В текущей среде можно проверить синтаксис shell:

```sh
sh -n iptv-manager.sh
```

Полноценную проверку multicast нельзя выполнить без конкретного роутера и действующего подключения Ростелекома.
