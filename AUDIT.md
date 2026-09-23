# Deep audit — v4.3.3

## Scope

Проверены shell-синтаксис, UCI-связи, network/firewall/dhcp/igmpproxy интеграции, backup/restore/uninstall, hotplug, VLAN/DSA ограничения, package manager и пользовательский CLI.

## Исправлено в этом проходе

1. **Classic topology** — убран отдельный `network.rt_iptv` на физическом WAN. Upstream `igmpproxy` использует существующую `network.wan`, что соответствует базовой OpenWrt IPTV-схеме и снижает риск конфликтов netifd.
2. **UCI collisions** — перед установкой проверяются все проектные section names. Чужие секции не перезаписываются.
3. **Transaction order** — backup выполняется до изменения выбранного порта и state-файлов.
4. **Rollback** — восстанавливаются UCI, проектный hotplug и state/portmap.
5. **State write** — состояние записывается через временный файл и `mv`; при ошибке выполняется rollback.
6. **altnet** — поддерживается IPv4 и IPv4/CIDR; одиночный адрес нормализуется в `/32`; дубликаты не добавляются.
7. **UX** — добавлен `plan` для безопасного просмотра обнаруженной топологии и ограничений без изменения конфигурации.
8. **DSA safety** — VLAN ID/bridge-vlan схема не угадываются. Legacy `parent.VID` используется только в явно выбранном VLAN-режиме.

## Static checks

- `sh -n iptv-manager.sh` — PASS
- `busybox sh -n iptv-manager.sh` — PASS
- CLI `help` — PASS
- unknown command returns non-zero — PASS
- архив содержит только ожидаемые файлы проекта — PASS
- не обнаружены `curl`, `wget`, `uclient-fetch` или удалённые config downloads в installer
- не обнаружено hard-coded WAN MAC
- не выполняется полная перезапись `/etc/config/network`, `/etc/config/firewall`, `/etc/config/dhcp`, `/etc/config/igmpproxy`

## Runtime limitations

Полноценный multicast E2E-тест невозможен без реального OpenWrt-роутера с активной линией Ростелекома. Поэтому VLAN ID, upstream addressing и набор `altnet` нельзя считать универсальными.

Для DSA VLAN OpenWrt использует `bridge-vlan`; проект намеренно не создаёт такую топологию автоматически без данных о конкретном роутере и схеме провайдера.

## 4.3.3 hardening

1. **Project-scoped automatic rollback** — критическая ошибка установки больше не восстанавливает целиком четыре `/etc/config/*` файла. Откатываются только проектные UCI-секции, выбранный IPTV-порт и проектный hotplug.
2. **PPPoE/logical WAN** — Classic проверяет наличие `network.wan`, но не требует, чтобы `network.wan.device` был физическим `eth*`/`lan*`. Это позволяет не блокировать логические WAN topology без изменения WAN credentials.
3. **IGMP version** — принудительный `igmpversion=2` удалён из default path; доступен явный `IGMP_VERSION=1|2|3`.
4. **Diagnostics** — добавлен вывод WAN protocol, текущих `altnet` и потенциальных multicast-source сообщений из system log.

## Remaining runtime limitation

Без реального роутера и активной линии Ростелекома нельзя доказать E2E multicast forwarding, корректность конкретного регионального VLAN ID или полный набор source IP. Эти параметры остаются topology-dependent.


## Дополнительный проход 4.3.3

- Проверен жизненный цикл `backup → staged UCI → commit → reload → state`.
- Обнаружен и исправлен риск в полном `restore`: `uci commit` после прямой замены файлов мог сохранить старые staged changes поверх backup.
- Проверена обработка пользовательского hotplug при ошибках копирования/chmod.
- Проверена последовательность установки пакета `igmpproxy`: интерактивная отмена теперь не оставляет неожиданный пакет после выбора порта.
- Проверен UX мастера: link state, bridge membership, явное подтверждение и понятное предупреждение перед отделением порта.
- GitHub Actions не использует сторонний ShellCheck action; используется ShellCheck 0.9.0 из Ubuntu 24.04 runner image и полный SHA для checkout. Runner image содержит ShellCheck в установленном наборе ПО.
- Остаётся обязательное ограничение: без реальной линии Ростелекома нельзя доказать E2E multicast, конкретный VLAN ID и региональный набор source IP.

- Firewall downstream reviewed: management exposure reduced by default (`input REJECT`) while DHCP/DNS/IGMP remain explicitly allowed; multicast forwarding remains a dedicated forwarded rule.
