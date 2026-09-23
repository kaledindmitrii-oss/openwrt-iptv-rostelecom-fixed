# Changelog

## 5.5.0
- Added explicit Shared-WAN profile for verified PPPoE + physical WAN/L2 IPTV topologies.
- Added conservative DSA bridge-vlan profile without guessing switch/CPU topology.
- Added topology guards for both profiles.
- Extended runtime post-checks for DSA VLAN interfaces.
- Kept legacy VLAN mode blocked on DSA.
- Updated GitHub-ready documentation and static checks.

# Changelog

## 5.4.0 — Deep audit fixes

- Deep safety rebuild on top of v5.0 architecture.
- Clean-UCI precondition before mutating install/uninstall/restore flows.
- DSA `bridge-vlan` membership is saved, removed and restored alongside bridge device ports.
- Transaction lock is acquired for every mutating/diagnostic command except help/version.
- Rollback no longer performs broad `uci revert`; it removes only project-owned sections and restores captured port membership.
- Backup captures project state, portmap, altnets, hotplug and igmpproxy service state.
- Restore creates a pre-restore backup and restores project state coherently.
- Uninstall preserves the original igmpproxy enabled/running state.
- Runtime altnet changes are applied to igmpproxy and rolled back if restart fails.
- Stronger post-install checks for bridge, VLAN runtime interface, firewall, DHCP and igmpproxy.
- Atomic hotplug handling and safer rollback retention.
- Backup MANIFEST and complete missing-state markers added; restore now restores original hotplug state coherently.
- Stale lock detection added.
- Multi-value altnet rollback fixed.
- No remote downloads, WAN MAC changes or PPPoE credential handling.

## 5.3.0 — Clean rebuild

- Initial clean rebuild baseline; see git history for the full 5.3.0 change set.

# Changelog

## 5.3.0 — Clean rebuild

- Полностью пересобран проект вместо последовательных patch v4.3.x.
- Новая транзакционная архитектура установки.
- Защита WAN/management bridge path с bounded recursive topology check.
- Classic использует существующий `network.wan` без второго L3-интерфейса на WAN.
- Legacy VLAN отделён и требует явный физический parent + VLAN ID.
- DSA обнаруживается и блокирует legacy VLAN wizard вместо угадывания bridge-vlan схемы.
- Project rollback не заменяет целиком пользовательские конфиги.
- Full restore оставлен отдельной явно подтверждаемой операцией.
- Атомарный hotplug install/restore.
- `opkg` и `apk`.
- `status`, `diagnose`, `plan`, `list-ports`, `show-config`, `backup`, `restore`, `uninstall`.
- Управление `altnet`.
- IGMP version не принуждается по умолчанию.
- CI переведён на прямой ShellCheck без стороннего action.
