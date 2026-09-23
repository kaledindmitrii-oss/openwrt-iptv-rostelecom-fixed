# OpenWrt IPTV Ростелеком — Fixed 5.5.0

Независимый проект для настройки IPTV Ростелеком на OpenWrt с `igmpproxy`.

**Проект НЕ является частью Universal OpenWrt.**

## Что такое 5.3.0

Это не очередной patch v4.3.x. Версия 5.5.0 пересобрана как новый проект с нуля вокруг следующих принципов:

- изменения выполняются через UCI, без wholesale replacement пользовательских конфигов;
- перед изменением сохраняется backup;
- установка выполняется как транзакция с проектным rollback;
- физический IPTV-порт не может быть взят из WAN/management path;
- Classic не создаёт второй L3-интерфейс на WAN;
- legacy VLAN требует явного parent и VLAN ID;
- DSA VLAN намеренно не угадывается;
- hotplug создаётся атомарно и восстанавливается;
- `opkg` и `apk` поддерживаются;
- есть status/diagnose/plan/backup/restore/uninstall;
- есть управление multicast source `altnet`;
- CI выполняет `sh -n` и ShellCheck.

## Быстрый запуск

```sh
scp iptv-manager.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1
chmod +x /tmp/iptv-manager.sh
/tmp/iptv-manager.sh
```

Или:

```sh
/tmp/iptv-manager.sh install
```

## Classic

Classic использует существующую `network.wan` как upstream `igmpproxy` и выделяет отдельный физический Ethernet-порт под приставку.

Перед изменениями менеджер проверяет WAN/management path. Если выбранный порт входит в bridge, через который проходит WAN, он блокируется.

Создаются только проектные UCI-секции:

- `network.rt_iptv_dev`
- `network.rt_iptv_lan`
- `dhcp.rt_iptv_dhcp`
- `firewall.rt_iptv_*`
- `igmpproxy.rt_iptv_*`

## Legacy VLAN

```sh
/tmp/iptv-manager.sh install-vlan eth0 100 lan4
```

Это только синтаксический пример. VLAN ID Ростелекома зависит от конкретной схемы.

Legacy VLAN использует `8021q` и требует физический parent. На DSA-устройствах автоматическая legacy VLAN установка отключена, чтобы не разрушать существующую bridge-vlan схему. DSA необходимо настраивать по фактической топологии устройства.

## Multicast / altnet

Начальный список source IP взят из независимого reference-проекта и не считается универсальным.

```sh
/tmp/iptv-manager.sh add-altnet 212.12.12.236
/tmp/iptv-manager.sh remove-altnet 212.12.12.236
```

Менеджер не разрешает весь IPv4 диапазон автоматически.

## IGMP

По умолчанию версия IGMP не принуждается. Если ваша линия требует конкретную версию:

```sh
IGMP_VERSION=2 /tmp/iptv-manager.sh install
```

Допустимы 1, 2 и 3.

## Безопасность изменений

### Backup

Перед установкой создаётся:

```text
/root/iptv-rostelecom-backups/
```

Сохраняются `network`, `firewall`, `dhcp`, `igmpproxy` и состояние hotplug.

### Project rollback

При ошибке установки менеджер:

1. отменяет незакоммиченные UCI-изменения;
2. удаляет только свои UCI-секции;
3. возвращает исходное членство выбранного порта;
4. коммитит rollback;
5. перезапускает сетевые сервисы;
6. восстанавливает пользовательский hotplug.

### Full restore

Команда `restore` — отдельная аварийная операция. Она заменяет сохранённые целиком файлы `/etc/config/network`, `/etc/config/firewall`, `/etc/config/dhcp`, `/etc/config/igmpproxy`. Перед подтверждением менеджер показывает, что это destructive operation.

### Uninstall

`uninstall` удаляет только конфигурацию проекта и возвращает исходное членство IPTV-порта. Полный пользовательский конфиг не заменяется.

## Диагностика

```sh
/tmp/iptv-manager.sh status
/tmp/iptv-manager.sh plan
/tmp/iptv-manager.sh diagnose
```

`diagnose` выводит интерфейсы, адреса, `/proc/net/igmp`, процесс `igmpproxy`, релевантные `fw4` правила и свежие записи `logread`.

## Ограничения

- Это не официальная конфигурация Ростелекома.
- Реальная multicast topology зависит от региона, тарифа, доступа и оборудования.
- Нельзя подтвердить работу IPTV без реального роутера и активной линии Ростелекома.
- DSA VLAN не угадывается.
- Начальный `altnet` список является отправной точкой, а не гарантией для всех регионов.
- Явное multicast firewall rule оставлено для совместимости; современные версии `igmpproxy`/fw4 могут добавлять собственные правила, поэтому итоговую таблицу необходимо проверять на реальном роутере.


## v5.5 installation profiles

- `install` — Classic: uses the existing `network.wan` as igmpproxy upstream.
- `install-shared-wan PARENT IPTV_PORT` — for a verified PPPoE/shared-WAN topology; uses the physical WAN parent as a `proto=none` igmpproxy upstream and never creates DHCP/IP/routes on the provider-facing parent. Legacy only; DSA is rejected.
- `install-vlan PARENT VLAN_ID IPTV_PORT` — legacy 802.1Q only; rejected on DSA.
- `install-dsa BRIDGE VLAN_ID IPTV_PORT` — conservative DSA mode. It only adds a VLAN to an existing bridge already carrying the detected WAN and already containing the IPTV port. It does not guess CPU/DSA topology.

The DSA profile is intentionally conservative: verify the provider VLAN and existing bridge topology before applying it. No profile claims IPTV success without testing on the actual Rostelecom line.
