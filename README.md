# OpenWrt IPTV Ростелеком — Fixed

Независимый исправленный аналог `v1rtuozz/openwrt-iptv-rostelecom`.

**Проект НЕ является частью Universal OpenWrt.**

## Что изменено в 4.1.0

- Исправлена работа с UCI `list ports`.
- Физические Ethernet-порты определяются по `/sys/class/net/*/device`, без исключения `eth0`/`eth1` по имени.
- Установщик не меняет WAN/PPPoE.
- Без аргументов запускается простое меню.
- Добавлена пост-проверка после установки.
- Hotplug создаётся отдельным файлом `99-iptv-rostelecom` и не перезаписывает чужой hook.
- Усилена защита от ошибочной установки на bridge/VLAN/virtual interface.
- Сохраняются backup, rollback, uninstall и диагностика.

OpenWrt использует DSA на современных устройствах; для сложных VLAN-топологий OpenWrt рекомендует bridge/VLAN-конфигурацию, поэтому проект намеренно не пытается угадывать DSA VLAN-схему. citeturn0search0turn0search2

## Быстрый запуск

```sh
scp iptv-manager.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1
chmod +x /tmp/iptv-manager.sh
/tmp/iptv-manager.sh
```

Откроется меню:

```text
1) Установить IPTV
2) Проверить состояние
3) Диагностика
4) Показать порты
5) Показать конфигурацию
6) Создать backup
7) Удалить IPTV
0) Выход
```

Для автоматизации доступны команды:

```sh
/tmp/iptv-manager.sh install
/tmp/iptv-manager.sh status
/tmp/iptv-manager.sh diagnose
/tmp/iptv-manager.sh list-ports
/tmp/iptv-manager.sh show-config
/tmp/iptv-manager.sh backup
/tmp/iptv-manager.sh restore
/tmp/iptv-manager.sh uninstall
```

## Classic IPTV

`install` рассчитан на классическую схему multicast + IGMP proxy с отдельным физическим Ethernet-портом для приставки.

Установщик:

1. определяет OpenWrt и WAN device;
2. проверяет/устанавливает `igmpproxy` через доступный пакетный менеджер;
3. показывает физические Ethernet-порты;
4. просит выбрать IPTV-порт;
5. создаёт backup;
6. убирает выбранный порт из существующего bridge через UCI list-операции;
7. создаёт `br-rt-iptv` с IGMP snooping;
8. создаёт `rt_iptv_lan` и DHCP;
9. создаёт отдельные firewall zones/rules;
10. настраивает `igmpproxy`;
11. применяет конфигурацию и выполняет пост-проверку.

WAN credentials и PPPoE установщик не изменяет.

## VLAN

Если конкретная схема Ростелекома требует VLAN, VLAN ID должен быть известен заранее.

Пример старого/простого L2 parent:

```sh
/tmp/iptv-manager.sh install-vlan eth0 100 lan4
```

`100` — только пример. Проект не утверждает, что это VLAN Ростелекома.

Для DSA-схем, где VLAN должен быть построен через `br-lan.<VID>`/`bridge-vlan`, используйте штатную UCI/LuCI-конфигурацию OpenWrt. Не переносите пример `eth0.<VID>` на DSA-роутер вслепую. OpenWrt прямо описывает различия между legacy swconfig и DSA. citeturn0search0turn0search1

## Multicast source / altnet

В проекте сохранён стартовый набор source IP из исходного аналога. Он не считается универсальным для всех регионов.

Добавить источник:

```sh
/tmp/iptv-manager.sh add-altnet 212.12.12.236
```

Удалить источник:

```sh
/tmp/iptv-manager.sh remove-altnet 212.12.12.236
```

Не следует без необходимости разрешать весь IPv4 диапазон как `altnet`: смысл `altnet` — ограничивать допустимые multicast sources.

## Диагностика

```sh
/tmp/iptv-manager.sh status
/tmp/iptv-manager.sh diagnose
```

Полезные системные команды:

```sh
cat /proc/net/igmp
logread -f | grep -Ei 'igmp|igmpproxy|multicast|netifd'
fw4 print | grep -Ei 'rt_iptv|224\.0\.0\.0/4|igmpproxy'
```

## Backup / rollback

Перед установкой создаётся backup:

```text
/root/iptv-rostelecom-backups/
```

Восстановление:

```sh
/tmp/iptv-manager.sh restore
```

`restore` заменяет сохранённые целиком файлы `network`, `firewall`, `dhcp`, `igmpproxy`. Используйте его именно как аварийный rollback к состоянию backup.

`uninstall` удаляет только секции проекта и не делает полный откат пользовательских изменений.

## Важные ограничения

- Это не официальная конфигурация Ростелекома.
- Multicast topology может отличаться по региону, доступу и оборудованию.
- Не угадывается VLAN ID.
- Полную IPTV-проверку нельзя выполнить без реального OpenWrt-роутера и действующего подключения.
- Статические `10.0.0.1/24` и `192.168.100.1/24` сохранены как совместимость с исходной схемой; если конкретное подключение использует другую L2/L3 схему, параметры нужно адаптировать.

## Проверка проекта

```sh
sh -n iptv-manager.sh
```

Также проект содержит GitHub Actions для shell syntax/ShellCheck.
