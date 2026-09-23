# Deep rebuild audit — 5.5.0

## Scope

This release was rebuilt independently rather than patching v4.3.x in place.

## Design decisions

1. **No wholesale config replacement during normal install/rollback.** Project UCI sections are created/removed with UCI operations.
2. **Transactional installation.** Backup and original port membership are captured before project changes. On failure, staged UCI changes are reverted, project sections are removed, port membership is restored, and services are reloaded.
3. **WAN/management safety.** Physical IPTV ports are rejected when they are the WAN device, WAN VLAN parent, or reachable through the WAN bridge topology. The topology walk is bounded to prevent loops.
4. **Classic topology.** Existing `network.wan` is used as the igmpproxy upstream. The installer does not create a second L3 interface on the WAN.
5. **VLAN topology.** Only explicit legacy 802.1q parent + VLAN ID are supported. DSA systems stop before legacy VLAN configuration instead of guessing `bridge-vlan` membership.
6. **Multicast source allow-list.** A regional starting set is kept as editable `altnet` state. It is not treated as universal.
7. **IGMP version.** No version is forced by default. `IGMP_VERSION=1|2|3` is optional.
8. **Firewall.** Dedicated IPTV zones/rules are created with restrictive input/forward defaults and explicit IGMP/DHCP/DNS/multicast allowances.
9. **Hotplug.** The project hook is written atomically. Existing user hook content is backed up and restored on uninstall/rollback.
10. **Package managers.** Both `opkg` and `apk` are supported.
11. **Diagnostics.** Status, plan and diagnose commands expose topology, interfaces, multicast state, igmpproxy process, fw4 rules and recent logs.
12. **Full restore is explicit.** Whole-file restore is separated from project rollback and requires confirmation.

## Known limitations

- No real Rostelecom line/router test is available in this environment.
- Regional VLAN IDs and multicast source addresses cannot be inferred universally.
- DSA bridge-vlan configuration is intentionally not generated automatically.
- Current firewall multicast compatibility rules should be checked against the exact installed igmpproxy/fw4 behavior on hardware.
- The WAN-path topology walk is bounded to 8 levels and is designed for normal OpenWrt device/bridge graphs.

## Local validation performed

- `sh -n iptv-manager.sh` — PASS
- `sh tests/static-audit.sh` — PASS
- `busybox sh -n iptv-manager.sh` — PASS
- `git diff --check` — PASS after clean rebuild staging
- `--version` — PASS (`5.5.0`)
- `--help` — PASS
- unknown command returns exit code 1 — PASS
- no installer `curl`/`wget`/`uclient-fetch`/HTTP(S) download logic — PASS
- no hardcoded WAN MAC or PPPoE credentials — PASS
- no wholesale `/etc/config/*` replacement in normal installer — PASS

ShellCheck must be confirmed by GitHub Actions on the rebuilt branch; it is not installed in the local validation environment.

## v5.5 topology hardening
- Shared-WAN is explicit and never creates DHCP/IP/routes on the provider-facing physical parent.
- Legacy 802.1Q remains blocked on DSA.
- DSA mode only operates on an existing bridge carrying detected WAN and selected IPTV port.
- DSA mode adds `bridge-vlan` with tagged bridge self-port and untagged IPTV port.
- Runtime post-check verifies the resulting VLAN device.
