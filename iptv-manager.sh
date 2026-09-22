#!/bin/sh
# OpenWrt IPTV Rostelecom Manager
# Independent project - NOT part of Universal OpenWrt
# Version: 4.1.0
# Simple interactive UI + safe UCI changes + multicast diagnostics.

set -u

VERSION="4.1.0"
PROJECT="iptv-rostelecom"
STATE_DIR="/etc/iptv-rostelecom"
BACKUP_DIR="/root/iptv-rostelecom-backups"
CONFIG_FILE="$STATE_DIR/config"
PORTMAP_FILE="$STATE_DIR/portmap"
HOTPLUG_FILE="/etc/hotplug.d/iface/99-iptv-rostelecom"
ALTNETS="198.18.20.5 10.179.47.27 10.171.151.11 212.12.12.235 212.12.12.234 212.193.149.193 212.193.157.250 46.235.189.194 195.209.81.195 212.193.155.254 212.193.153.129 212.193.155.240 65.9.46.41"

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

log() { printf '%s\n' "$*"; }
die() { log "\nОШИБКА: $*"; exit 1; }
is_root() { [ "$(id -u 2>/dev/null)" = "0" ] || die "Запустите скрипт от root."; }
uci_get() { uci -q get "$1" 2>/dev/null; }
uci_del() { uci -q delete "$1" 2>/dev/null || true; }
confirm() { printf "%s [y/N]: " "$1"; read -r ans; case "$ans" in y|Y|д|Д) return 0;; *) return 1;; esac; }
openwrt_version() { [ -r /etc/openwrt_release ] || die "Это не похоже на OpenWrt."; . /etc/openwrt_release; printf '%s' "${DISTRIB_RELEASE:-unknown}"; }

pause_ui() { printf '\nНажмите Enter для продолжения...'; read -r _; }
header() { clear 2>/dev/null || true; printf '\n========================================\n  OpenWrt IPTV Ростелеком  v%s\n========================================\n' "$VERSION"; }

pkg_install() {
    if command -v apk >/dev/null 2>&1; then
        apk add igmpproxy >/dev/null 2>&1 || { apk update >/dev/null 2>&1 || true; apk add igmpproxy || die "Не удалось установить igmpproxy через apk."; }
    elif command -v opkg >/dev/null 2>&1; then
        opkg install igmpproxy >/dev/null 2>&1 || { opkg update >/dev/null 2>&1 || true; opkg install igmpproxy || die "Не удалось установить igmpproxy через opkg."; }
    else die "Не найден apk/opkg."; fi
}
ensure_igmpproxy() { command -v igmpproxy >/dev/null 2>&1 && return 0; log "Устанавливаю igmpproxy..."; pkg_install; command -v igmpproxy >/dev/null 2>&1 || die "igmpproxy после установки не найден."; }
timestamp() { date '+%Y%m%d-%H%M%S'; }

backup() {
    tag="${1:-manual}"; dir="$BACKUP_DIR/$(timestamp)-$tag"; mkdir -p "$dir"
    for f in network firewall dhcp igmpproxy; do [ -f "/etc/config/$f" ] && cp "/etc/config/$f" "$dir/$f"; done
    [ -f "$HOTPLUG_FILE" ] && cp "$HOTPLUG_FILE" "$dir/hotplug" || true
    printf '%s\n' "$dir" > "$STATE_DIR/last_backup"
    log "Резервная копия: $dir"
}
latest_backup() { if [ -r "$STATE_DIR/last_backup" ]; then cat "$STATE_DIR/last_backup"; return 0; fi; ls -1dt "$BACKUP_DIR"/* 2>/dev/null | head -n 1; }
restore_backup() {
    dir="$(latest_backup)"; [ -n "$dir" ] && [ -d "$dir" ] || die "Резервная копия не найдена."
    log "Восстановление из: $dir"
    /etc/init.d/igmpproxy stop >/dev/null 2>&1 || true
    for f in network firewall dhcp igmpproxy; do [ -f "$dir/$f" ] && cp "$dir/$f" "/etc/config/$f"; done
    if [ -f "$dir/hotplug" ]; then cp "$dir/hotplug" "$HOTPLUG_FILE"; chmod +x "$HOTPLUG_FILE"; else rm -f "$HOTPLUG_FILE"; fi
    uci commit network; uci commit firewall; uci commit dhcp; uci commit igmpproxy
    /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true
    log "Восстановление завершено."
}

detect_wan_device() { WAN_DEV="$(uci_get network.wan.device)"; [ -n "${WAN_DEV:-}" ] || WAN_DEV="$(uci_get network.wan.ifname)"; [ -n "${WAN_DEV:-}" ] || WAN_DEV="wan"; printf '%s' "$WAN_DEV"; }

is_virtual_iface() {
    case "$1" in lo|br-*|docker*|veth*|ppp*|tun*|wg*|sit*|gre*|gretap*|ip6tnl*|bond*|dummy*|ifb*) return 0;; esac
    return 1
}
list_ports() {
    wan="$(detect_wan_device)"
    for p in /sys/class/net/*; do
        n="${p##*/}"
        is_virtual_iface "$n" && continue
        [ "$n" = "$wan" ] && continue
        [ -e "$p/device" ] || continue
        printf '%s\n' "$n"
    done | sort
}
valid_ipv4() { echo "$1" | awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i<0 || $i>255) exit 1; exit 0} {exit 1}'; }
validate_vid() { echo "$1" | awk '$0 ~ /^[0-9]+$/ && $1 >= 1 && $1 <= 4094 {exit 0} {exit 1}'; }

save_port_membership() {
    port="$1"; : > "$PORTMAP_FILE"
    for sec in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
        name="$(uci_get "network.$sec.name")"; ports="$(uci_get "network.$sec.ports")"; [ -n "$name" ] || continue
        for item in $ports; do [ "$item" = "$port" ] && printf '%s\t%s\n' "$name" "$ports" >> "$PORTMAP_FILE"; done
    done
}
restore_port_membership() {
    [ -r "$PORTMAP_FILE" ] || return 0
    while IFS="$(printf '\t')" read -r name ports; do
        [ -n "$name" ] || continue; found=""
        for sec in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do [ "$(uci_get "network.$sec.name")" = "$name" ] && { found="$sec"; break; }; done
        [ -n "$found" ] || continue
        for item in $ports; do uci add_list "network.$found.ports=$item"; done
    done < "$PORTMAP_FILE"
}
remove_port_from_bridges() {
    port="$1"
    for sec in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
        ports="$(uci_get "network.$sec.ports")"; [ -n "$ports" ] || continue
        for item in $ports; do [ "$item" = "$port" ] && uci del_list "network.$sec.ports=$port" 2>/dev/null || true; done
    done
}

select_port() {
    WAN_DEV="$(detect_wan_device)"
    log "WAN: $WAN_DEV"
    log "\nФизические Ethernet-порты:"
    ports="$(list_ports)"; [ -n "$ports" ] || die "Физические Ethernet-порты не найдены."
    printf '  %s\n' $ports
    printf '\nВведите порт IPTV (например lan4): '; read -r IPTV_PORT
    [ -n "$IPTV_PORT" ] || die "Порт не указан."
    is_virtual_iface "$IPTV_PORT" && die "Выберите физический Ethernet-порт: $IPTV_PORT"
    case "$IPTV_PORT" in *.*|*@*) die "Выберите физический Ethernet-порт: $IPTV_PORT";; esac
    [ -e "/sys/class/net/$IPTV_PORT/device" ] || die "Физический интерфейс не найден: $IPTV_PORT"
    [ "$IPTV_PORT" != "$WAN_DEV" ] || die "Нельзя выбрать WAN как IPTV-порт."
    save_port_membership "$IPTV_PORT"
    printf '%s\n' "$IPTV_PORT" > "$STATE_DIR/iptv_port"
}

remove_owned_config() {
    for sec in rt_iptv_lan rt_iptv_dev rt_iptv rt_iptv_vlan; do uci_del "network.$sec"; done
    uci_del dhcp.rt_iptv_dhcp
    for sec in rt_iptv_igmp rt_iptv_upstream rt_iptv_downstream; do uci_del "igmpproxy.$sec"; done
    for sec in rt_iptv_upstream rt_iptv_downstream rt_iptv_igmp_accept rt_iptv_igmp_downstream rt_iptv_multicast; do uci_del "firewall.$sec"; done
}
configure_network() {
    port="$1"; wan_dev="$2"; mode="$3"; vid="${4:-}"
    remove_owned_config
    remove_port_from_bridges "$port"
    uci set network.rt_iptv_dev='device'
    uci set network.rt_iptv_dev.name='br-rt-iptv'
    uci set network.rt_iptv_dev.type='bridge'
    uci add_list network.rt_iptv_dev.ports="$port"
    uci set network.rt_iptv_dev.igmp_snooping='1'
    uci set network.rt_iptv_dev.igmpversion='2'
    uci set network.rt_iptv_lan='interface'
    uci set network.rt_iptv_lan.proto='static'
    uci set network.rt_iptv_lan.device='br-rt-iptv'
    uci set network.rt_iptv_lan.ipaddr='192.168.100.1'
    uci set network.rt_iptv_lan.netmask='255.255.255.0'
    uci set network.rt_iptv_lan.delegate='0'
    if [ "$mode" = "vlan" ]; then
        case "$wan_dev" in br-*|ppp*|tun*|wg*|*.*) die "Для VLAN нужен физический parent-интерфейс, а не $wan_dev. Для DSA используйте bridge VLAN через LuCI/UCI.";; esac
        uci set network.rt_iptv_vlan='device'
        uci set network.rt_iptv_vlan.name="$wan_dev.$vid"
        uci set network.rt_iptv_vlan.type='8021q'
        uci set network.rt_iptv_vlan.ifname="$wan_dev"
        uci set network.rt_iptv_vlan.vid="$vid"
        wan_dev="$wan_dev.$vid"
    fi
    uci set network.rt_iptv='interface'
    uci set network.rt_iptv.proto='static'
    uci set network.rt_iptv.device="$wan_dev"
    uci set network.rt_iptv.ipaddr='10.0.0.1'
    uci set network.rt_iptv.netmask='255.255.255.0'
    uci set network.rt_iptv.defaultroute='0'
    uci set network.rt_iptv.peerdns='0'
    uci set network.rt_iptv.delegate='0'
}
configure_dhcp() { uci set dhcp.rt_iptv_dhcp='dhcp'; uci set dhcp.rt_iptv_dhcp.interface='rt_iptv_lan'; uci set dhcp.rt_iptv_dhcp.start='100'; uci set dhcp.rt_iptv_dhcp.limit='150'; uci set dhcp.rt_iptv_dhcp.leasetime='12h'; uci set dhcp.rt_iptv_dhcp.force='1'; }
configure_firewall() {
    uci set firewall.rt_iptv_upstream='zone'; uci set firewall.rt_iptv_upstream.name='rt_iptv_upstream'; uci add_list firewall.rt_iptv_upstream.network='rt_iptv'; uci set firewall.rt_iptv_upstream.input='REJECT'; uci set firewall.rt_iptv_upstream.output='ACCEPT'; uci set firewall.rt_iptv_upstream.forward='REJECT'; uci set firewall.rt_iptv_upstream.masq='0'
    uci set firewall.rt_iptv_downstream='zone'; uci set firewall.rt_iptv_downstream.name='rt_iptv_lan'; uci add_list firewall.rt_iptv_downstream.network='rt_iptv_lan'; uci set firewall.rt_iptv_downstream.input='ACCEPT'; uci set firewall.rt_iptv_downstream.output='ACCEPT'; uci set firewall.rt_iptv_downstream.forward='REJECT'
    uci set firewall.rt_iptv_igmp_accept='rule'; uci set firewall.rt_iptv_igmp_accept.name='Rostelecom IPTV IGMP upstream'; uci set firewall.rt_iptv_igmp_accept.src='rt_iptv_upstream'; uci set firewall.rt_iptv_igmp_accept.proto='igmp'; uci set firewall.rt_iptv_igmp_accept.family='ipv4'; uci set firewall.rt_iptv_igmp_accept.target='ACCEPT'
    uci set firewall.rt_iptv_igmp_downstream='rule'; uci set firewall.rt_iptv_igmp_downstream.name='Rostelecom IPTV IGMP downstream'; uci set firewall.rt_iptv_igmp_downstream.src='rt_iptv_lan'; uci set firewall.rt_iptv_igmp_downstream.proto='igmp'; uci set firewall.rt_iptv_igmp_downstream.family='ipv4'; uci set firewall.rt_iptv_igmp_downstream.target='ACCEPT'
    uci set firewall.rt_iptv_multicast='rule'; uci set firewall.rt_iptv_multicast.name='Rostelecom IPTV multicast'; uci set firewall.rt_iptv_multicast.src='rt_iptv_upstream'; uci set firewall.rt_iptv_multicast.dest='rt_iptv_lan'; uci set firewall.rt_iptv_multicast.family='ipv4'; uci set firewall.rt_iptv_multicast.proto='udp'; uci set firewall.rt_iptv_multicast.dest_ip='224.0.0.0/4'; uci set firewall.rt_iptv_multicast.target='ACCEPT'
}
configure_igmpproxy() {
    uci set igmpproxy.rt_iptv_igmp='igmpproxy'; uci set igmpproxy.rt_iptv_igmp.quickleave='1'; uci set igmpproxy.rt_iptv_igmp.verbose='0'
    uci set igmpproxy.rt_iptv_upstream='phyint'; uci set igmpproxy.rt_iptv_upstream.network='rt_iptv'; uci set igmpproxy.rt_iptv_upstream.zone='rt_iptv_upstream'; uci set igmpproxy.rt_iptv_upstream.direction='upstream'
    for ip in $ALTNETS; do uci add_list igmpproxy.rt_iptv_upstream.altnet="$ip"; done
    uci set igmpproxy.rt_iptv_downstream='phyint'; uci set igmpproxy.rt_iptv_downstream.network='rt_iptv_lan'; uci set igmpproxy.rt_iptv_downstream.zone='rt_iptv_lan'; uci set igmpproxy.rt_iptv_downstream.direction='downstream'
}
install_hotplug() {
    cat > "$HOTPLUG_FILE" <<EOF2
#!/bin/sh
# $PROJECT $VERSION
[ "\$ACTION" = "ifup" ] || exit 0
case "\$INTERFACE" in wan|rt_iptv) /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true ;; esac
exit 0
EOF2
    chmod +x "$HOTPLUG_FILE"
}
remove_hotplug() { [ -f "$HOTPLUG_FILE" ] && grep -q "$PROJECT" "$HOTPLUG_FILE" 2>/dev/null && rm -f "$HOTPLUG_FILE"; }
validate() {
    uci show network >/dev/null || die "Ошибка UCI network."
    uci show firewall >/dev/null || die "Ошибка UCI firewall."
    uci show dhcp >/dev/null || die "Ошибка UCI dhcp."
    uci show igmpproxy >/dev/null || die "Ошибка UCI igmpproxy."
    uci -q get network.rt_iptv.device >/dev/null || die "rt_iptv interface не создан."
    uci -q get network.rt_iptv_lan.device >/dev/null || die "rt_iptv_lan interface не создан."
    uci -q get firewall.rt_iptv_multicast.dest_ip >/dev/null || die "Multicast firewall rule не создан."
}
apply() {
    uci commit network; uci commit firewall; uci commit dhcp; uci commit igmpproxy
    /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    /etc/init.d/igmpproxy enable >/dev/null 2>&1 || true
    /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true
}
write_state() {
    mode="$1"; port="$2"; wan="$3"; vid="${4:-}"
    cat > "$CONFIG_FILE" <<EOF2
VERSION=$VERSION
MODE=$mode
IPTV_PORT=$port
WAN_DEVICE=$wan
VLAN_ID=$vid
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
EOF2
}
post_check() {
    log "\nПроверка после установки..."
    uci -q get network.rt_iptv.device >/dev/null && log "✓ IPTV upstream: $(uci_get network.rt_iptv.device)" || log "✗ IPTV upstream не найден"
    [ -d /sys/class/net/br-rt-iptv ] && log "✓ IPTV bridge: br-rt-iptv" || log "! Bridge ещё не поднялся"
    pidof igmpproxy >/dev/null 2>&1 && log "✓ igmpproxy запущен" || log "! igmpproxy не запущен — запустите diagnose"
    log "\nГотово. Подключите приставку к выбранному IPTV-порту и выполните: $0 status"
}
install_classic() {
    is_root; ensure_igmpproxy; select_port; port="$(cat "$STATE_DIR/iptv_port")"; wan="$(detect_wan_device)"
    case "$wan" in br-*|ppp*|tun*|wg*|*.*) die "WAN device '$wan' не является простым физическим интерфейсом. Для VLAN/DSA используйте отдельную настройку через LuCI/UCI.";; esac
    backup "before-install"; configure_network "$port" "$wan" classic; configure_dhcp; configure_firewall; configure_igmpproxy; install_hotplug; validate; apply; write_state classic "$port" "$wan"; post_check
}
install_vlan() {
    is_root; ensure_igmpproxy; parent="${2:-}"; vid="${3:-}"; port="${4:-}"
    [ -n "$parent" ] && [ -n "$vid" ] && [ -n "$port" ] || die "Использование: $0 install-vlan <physical-parent> <vid> <port>"
    [ -e "/sys/class/net/$parent/device" ] || die "Parent должен быть физическим интерфейсом: $parent"
    validate_vid "$vid" || die "VLAN ID должен быть 1..4094."
    [ -e "/sys/class/net/$port/device" ] || die "IPTV-порт не найден: $port"
    [ "$parent" != "$port" ] || die "Parent и IPTV-порт не могут совпадать."
    save_port_membership "$port"; printf '%s\n' "$port" > "$STATE_DIR/iptv_port"; backup before-vlan-install
    configure_network "$port" "$parent" vlan "$vid"; configure_dhcp; configure_firewall; configure_igmpproxy; install_hotplug; validate; apply; write_state vlan "$port" "$parent" "$vid"; post_check
}

status() {
    is_root; header
    [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || log "Состояние проекта не найдено."
    log "\n--- Сеть ---"; uci show network.rt_iptv 2>/dev/null || true; uci show network.rt_iptv_lan 2>/dev/null || true; uci show network.rt_iptv_dev 2>/dev/null || true; uci show network.rt_iptv_vlan 2>/dev/null || true
    log "--- DHCP ---"; uci show dhcp.rt_iptv_dhcp 2>/dev/null || true
    log "--- Firewall ---"; uci show firewall | grep -E 'rt_iptv' 2>/dev/null || true
    log "--- IGMP ---"; uci show igmpproxy | grep -E 'rt_iptv' 2>/dev/null || true
    log "--- Интерфейсы ---"; ip -br link 2>/dev/null | grep -E 'br-rt-iptv|rt_iptv|lan|eth' || true
    log "--- igmpproxy ---"; pidof igmpproxy 2>/dev/null || log "не запущен"
    command -v fw4 >/dev/null 2>&1 && { log "--- fw4 multicast ---"; fw4 print 2>/dev/null | grep -E 'rt_iptv|224\.0\.0\.0/4|igmpproxy' | tail -n 40 || true; }
}
diagnose() {
    is_root; header; log "OpenWrt: $(openwrt_version)"; log "WAN: $(detect_wan_device)"
    log "\n--- Адреса ---"; ip -br addr 2>/dev/null | grep -E 'rt_iptv|br-rt-iptv|wan|eth|lan' || true
    log "--- Маршруты multicast ---"; ip route 2>/dev/null | grep -E '224\.0\.0\.0|10\.0\.0\.0/24|192\.168\.100\.0/24' || true
    log "--- igmpproxy ---"; pidof igmpproxy 2>/dev/null || log "NOT RUNNING"
    log "--- /proc/net/igmp ---"; cat /proc/net/igmp 2>/dev/null || true
    log "--- Логи ---"; logread 2>/dev/null | grep -Ei 'igmp|igmpproxy|multicast|netifd' | tail -n 80 || true
    command -v fw4 >/dev/null 2>&1 && { log "--- Firewall ---"; fw4 print 2>/dev/null | grep -E 'rt_iptv|224\.0\.0\.0/4|igmpproxy' | tail -n 80 || true; }
}
list_ports_cmd() { is_root; log "WAN: $(detect_wan_device)"; log "Физические порты:"; list_ports; }
show_config() { is_root; header; for cfg in network firewall dhcp igmpproxy; do log "--- $cfg ---"; uci show "$cfg" | grep -E 'rt_iptv' || true; done; }
add_altnet() { is_root; ip="${1:-}"; [ -n "$ip" ] || die "Использование: $0 add-altnet <IPv4>"; valid_ipv4 "$ip" || die "Некорректный IPv4: $ip"; uci add_list igmpproxy.rt_iptv_upstream.altnet="$ip"; uci commit igmpproxy; /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true; log "Добавлен altnet: $ip"; }
remove_altnet() { is_root; ip="${1:-}"; [ -n "$ip" ] || die "Использование: $0 remove-altnet <IPv4>"; valid_ipv4 "$ip" || die "Некорректный IPv4: $ip"; uci del_list igmpproxy.rt_iptv_upstream.altnet="$ip" 2>/dev/null || true; uci commit igmpproxy; /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true; log "Удалён altnet: $ip"; }
uninstall() { is_root; backup before-uninstall; /etc/init.d/igmpproxy stop >/dev/null 2>&1 || true; port="$(cat "$STATE_DIR/iptv_port" 2>/dev/null || true)"; remove_owned_config; [ -n "$port" ] && restore_port_membership; remove_hotplug; uci commit network; uci commit firewall; uci commit dhcp; uci commit igmpproxy; /etc/init.d/network reload >/dev/null 2>&1 || true; /etc/init.d/firewall reload >/dev/null 2>&1 || true; /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true; /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true; rm -f "$CONFIG_FILE" "$STATE_DIR/iptv_port" "$PORTMAP_FILE"; log "Удаление завершено. Backup сохранён: $BACKUP_DIR"; }

show_help() {
cat <<EOF2
OpenWrt IPTV Ростелеком Manager $VERSION

Основные команды:
  $0                    простое меню
  $0 install            установить Classic IPTV
  $0 install-vlan <parent> <vid> <port>  VLAN IPTV
  $0 status              состояние
  $0 diagnose            диагностика
  $0 list-ports          физические порты
  $0 show-config         IPTV UCI-конфигурация
  $0 add-altnet <IPv4>   добавить multicast source
  $0 remove-altnet <IPv4> удалить multicast source
  $0 backup              backup
  $0 restore             restore последнего backup
  $0 uninstall           удалить только конфигурацию проекта
  $0 help                помощь
EOF2
}

menu() {
    is_root
    while :; do
        header
        printf '\n  1) Установить IPTV\n  2) Проверить состояние\n  3) Диагностика\n  4) Показать порты\n  5) Показать конфигурацию\n  6) Создать backup\n  7) Удалить IPTV\n  0) Выход\n\nВыберите действие: '
        read -r choice
        case "$choice" in
            1) install_classic; pause_ui;;
            2) status; pause_ui;;
            3) diagnose; pause_ui;;
            4) list_ports_cmd; pause_ui;;
            5) show_config; pause_ui;;
            6) backup manual; pause_ui;;
            7) if confirm "Удалить IPTV-конфигурацию проекта?"; then uninstall; fi; pause_ui;;
            0|q|Q) exit 0;;
            *) log "Неизвестный пункт."; pause_ui;;
        esac
    done
}

cmd="${1:-menu}"
case "$cmd" in
    menu) menu;;
    install) install_classic;;
    install-vlan) install_vlan "$@";;
    status) status;;
    diagnose) diagnose;;
    list-ports) list_ports_cmd;;
    show-config) show_config;;
    add-altnet) add_altnet "${2:-}";;
    remove-altnet) remove_altnet "${2:-}";;
    backup) is_root; backup manual;;
    restore) is_root; restore_backup;;
    uninstall) uninstall;;
    help|-h|--help) show_help;;
    *) die "Неизвестная команда: $cmd. Используйте: $0 help";;
esac
