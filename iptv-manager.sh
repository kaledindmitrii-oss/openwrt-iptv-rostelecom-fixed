#!/bin/sh
# OpenWrt IPTV Rostelecom Manager
# Independent project - NOT part of Universal OpenWrt
# Version: 4.3.1
# Simple interactive UI + safe UCI changes + multicast diagnostics.

set -u

VERSION="4.3.1"
PROJECT="iptv-rostelecom"
STATE_DIR="/etc/iptv-rostelecom"
BACKUP_DIR="/root/iptv-rostelecom-backups"
CONFIG_FILE="$STATE_DIR/config"
PORTMAP_FILE="$STATE_DIR/portmap"
HOTPLUG_FILE="/etc/hotplug.d/iface/99-iptv-rostelecom"
HOTPLUG_BACKUP="$STATE_DIR/original-hotplug"
ALTNETS="198.18.20.5/32 10.179.47.27/32 10.171.151.11/32 212.12.12.235/32 212.12.12.234/32 212.193.149.193/32 212.193.157.250/32 46.235.189.194/32 195.209.81.195/32 212.193.155.254/32 212.193.153.129/32 212.193.155.240/32 65.9.46.41/32"



log() { printf '%s\n' "$*"; }
die() { log "\nОШИБКА: $*"; exit 1; }
is_root() { [ "$(id -u 2>/dev/null)" = "0" ] || die "Запустите скрипт от root."; mkdir -p "$STATE_DIR" "$BACKUP_DIR" || die "Не удалось создать каталог состояния."; require_openwrt; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"; }
require_openwrt() { [ -r /etc/openwrt_release ] || die "Это не похоже на OpenWrt."; require_cmd uci; require_cmd ip; require_cmd awk; }
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
    tag="${1:-manual}"; dir="$BACKUP_DIR/$(timestamp)-$tag"; mkdir -p "$dir" || die "Не удалось создать backup."
    for f in network firewall dhcp igmpproxy; do
        if [ -f "/etc/config/$f" ]; then cp -p "/etc/config/$f" "$dir/$f"; else : > "$dir/$f.missing"; fi
    done
    if [ -f "$HOTPLUG_FILE" ]; then cp -p "$HOTPLUG_FILE" "$dir/hotplug" || die "Не удалось сохранить hotplug в backup."; else : > "$dir/hotplug.missing"; fi
    if [ -f "$CONFIG_FILE" ]; then cp -p "$CONFIG_FILE" "$dir/project-config"; else : > "$dir/project-config.missing"; fi
    if [ -f "$PORTMAP_FILE" ]; then cp -p "$PORTMAP_FILE" "$dir/portmap"; else : > "$dir/portmap.missing"; fi
    if [ -f "$STATE_DIR/iptv_port" ]; then cp -p "$STATE_DIR/iptv_port" "$dir/iptv_port"; else : > "$dir/iptv_port.missing"; fi
    if [ -f "$HOTPLUG_BACKUP" ]; then cp -p "$HOTPLUG_BACKUP" "$dir/original-hotplug"; else : > "$dir/original-hotplug.missing"; fi
    printf '%s\n' "$dir" > "$STATE_DIR/last_backup"
    log "Резервная копия: $dir"
}
latest_backup() { if [ -r "$STATE_DIR/last_backup" ]; then cat "$STATE_DIR/last_backup"; return 0; fi; ls -1dt "$BACKUP_DIR"/* 2>/dev/null | head -n 1; }
restore_backup() {
    is_root
    dir="$(latest_backup)"; [ -n "$dir" ] && [ -d "$dir" ] || die "Резервная копия не найдена."
    log "Восстановление из: $dir"
    /etc/init.d/igmpproxy stop >/dev/null 2>&1 || true
    for f in network firewall dhcp igmpproxy; do
        if [ -f "$dir/$f" ]; then cp "$dir/$f" "/etc/config/$f"; elif [ -f "$dir/$f.missing" ]; then rm -f "/etc/config/$f"; fi
    done
    if [ -f "$dir/hotplug" ]; then cp "$dir/hotplug" "$HOTPLUG_FILE"; chmod +x "$HOTPLUG_FILE"; elif [ -f "$dir/hotplug.missing" ]; then rm -f "$HOTPLUG_FILE"; fi
    if [ -f "$dir/project-config" ]; then cp "$dir/project-config" "$CONFIG_FILE"; elif [ -f "$dir/project-config.missing" ]; then rm -f "$CONFIG_FILE"; fi
    if [ -f "$dir/portmap" ]; then cp "$dir/portmap" "$PORTMAP_FILE"; elif [ -f "$dir/portmap.missing" ]; then rm -f "$PORTMAP_FILE"; fi
    if [ -f "$dir/iptv_port" ]; then cp "$dir/iptv_port" "$STATE_DIR/iptv_port"; elif [ -f "$dir/iptv_port.missing" ]; then rm -f "$STATE_DIR/iptv_port"; fi
    if [ -f "$dir/original-hotplug" ]; then cp "$dir/original-hotplug" "$HOTPLUG_BACKUP"; elif [ -f "$dir/original-hotplug.missing" ]; then rm -f "$HOTPLUG_BACKUP"; fi
    uci commit network; uci commit firewall; uci commit dhcp; uci commit igmpproxy
    /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true
    log "Восстановление завершено."
}

detect_wan_device() { WAN_DEV="$(uci_get network.wan.device)"; [ -n "${WAN_DEV:-}" ] || WAN_DEV="$(uci_get network.wan.ifname)"; [ -n "${WAN_DEV:-}" ] || WAN_DEV=""; printf '%s' "$WAN_DEV"; }

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
valid_altnet() {
    value="$1"
    case "$value" in
        */*) ip="${value%/*}"; prefix="${value#*/}";;
        *) ip="$value"; prefix=32;;
    esac
    valid_ipv4 "$ip" || return 1
    echo "$prefix" | awk '$0 ~ /^[0-9]+$/ && $1 >= 0 && $1 <= 32 {exit 0} {exit 1}'
}
normalize_altnet() { case "$1" in */*) printf '%s' "$1";; *) printf '%s/32' "$1";; esac; }
validate_vid() { echo "$1" | awk '$0 ~ /^[0-9]+$/ && $1 >= 1 && $1 <= 4094 {exit 0} {exit 1}'; }

save_port_membership() {
    port="$1"
    [ -s "$PORTMAP_FILE" ] && return 0
    : > "$PORTMAP_FILE"
    for sec in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
        name="$(uci_get "network.$sec.name")"; ports="$(uci_get "network.$sec.ports")"; [ -n "$name" ] || continue
        for item in $ports; do [ "$item" = "$port" ] && printf '%s\t%s\n' "$name" "$ports" >> "$PORTMAP_FILE"; done
    done
}
restore_port_membership() {
    port="${1:-}"
    [ -n "$port" ] || return 0
    [ -r "$PORTMAP_FILE" ] || return 0
    while IFS="$(printf '\t')" read -r name ports; do
        [ -n "$name" ] || continue; found=""
        for sec in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do [ "$(uci_get "network.$sec.name")" = "$name" ] && { found="$sec"; break; }; done
        [ -n "$found" ] || continue
        uci del_list "network.$found.ports=$port" 2>/dev/null || true
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
    # Classic uses logical network.wan as igmpproxy upstream.
    # The WAN device may be a VLAN or PPPoE parent, so it is not required
    # to be a physical interface here.
    if [ -n "$WAN_DEV" ] && [ "$IPTV_PORT" = "$WAN_DEV" ]; then
        die "Нельзя выбрать WAN как IPTV-порт."
    fi
}

remove_owned_config() {
    for sec in rt_iptv_lan rt_iptv_dev rt_iptv rt_iptv_vlan; do uci_del "network.$sec"; done
    uci_del dhcp.rt_iptv_dhcp
    for sec in rt_iptv_igmp rt_iptv_upstream rt_iptv_downstream; do uci_del "igmpproxy.$sec"; done
    for sec in rt_iptv_upstream rt_iptv_downstream rt_iptv_igmp_accept rt_iptv_igmp_downstream rt_iptv_multicast; do uci_del "firewall.$sec"; done
}
assert_project_names_free() {
    for key in network.rt_iptv_lan network.rt_iptv_dev network.rt_iptv network.rt_iptv_vlan dhcp.rt_iptv_dhcp igmpproxy.rt_iptv_igmp igmpproxy.rt_iptv_upstream igmpproxy.rt_iptv_downstream firewall.rt_iptv_upstream firewall.rt_iptv_downstream firewall.rt_iptv_igmp_accept firewall.rt_iptv_igmp_downstream firewall.rt_iptv_multicast; do
        if uci -q get "$key" >/dev/null 2>&1; then
            die "Обнаружена существующая UCI-секция $key. Для безопасности установщик не перезаписывает чужую конфигурацию."
        fi
    done
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
    # Do not force IGMPv2 by default. Set IGMP_VERSION=2 when the provider
    # or the target device explicitly requires IGMPv2.
    if [ -n "${IGMP_VERSION:-}" ]; then
        case "$IGMP_VERSION" in
            1|2|3) uci set network.rt_iptv_dev.igmpversion="$IGMP_VERSION" ;;
            *) die "IGMP_VERSION должен быть 1, 2 или 3." ;;
        esac
    fi
    uci set network.rt_iptv_lan='interface'
    uci set network.rt_iptv_lan.proto='static'
    uci set network.rt_iptv_lan.device='br-rt-iptv'
    uci set network.rt_iptv_lan.ipaddr='192.168.100.1'
    uci set network.rt_iptv_lan.netmask='255.255.255.0'
    uci set network.rt_iptv_lan.delegate='0'

    if [ "$mode" = "classic" ]; then
        # Classic mode uses the existing WAN network directly. No duplicate
        # L3 interface is created on the WAN device.
        :
    elif [ "$mode" = "vlan" ]; then
        case "$wan_dev" in br-*|ppp*|tun*|wg*|*.*) die "Для VLAN нужен физический parent-интерфейс, а не $wan_dev. Для DSA используйте bridge VLAN через LuCI/UCI.";; esac
        uci set network.rt_iptv_vlan='device'
        uci set network.rt_iptv_vlan.name="$wan_dev.$vid"
        uci set network.rt_iptv_vlan.type='8021q'
        uci set network.rt_iptv_vlan.ifname="$wan_dev"
        uci set network.rt_iptv_vlan.vid="$vid"
        uci set network.rt_iptv='interface'
        uci set network.rt_iptv.proto='dhcp'
        uci set network.rt_iptv.device="$wan_dev.$vid"
        uci set network.rt_iptv.defaultroute='0'
        uci set network.rt_iptv.peerdns='0'
        uci set network.rt_iptv.delegate='0'
    else
        die "Неизвестный режим сети: $mode"
    fi
}
configure_dhcp() { uci set dhcp.rt_iptv_dhcp='dhcp'; uci set dhcp.rt_iptv_dhcp.interface='rt_iptv_lan'; uci set dhcp.rt_iptv_dhcp.start='100'; uci set dhcp.rt_iptv_dhcp.limit='150'; uci set dhcp.rt_iptv_dhcp.leasetime='12h'; uci set dhcp.rt_iptv_dhcp.force='1'; }
configure_firewall() {
    if [ "$mode_choice_network" = "vlan" ]; then
        uci set firewall.rt_iptv_upstream='zone'; uci set firewall.rt_iptv_upstream.name='rt_iptv_upstream'; uci add_list firewall.rt_iptv_upstream.network='rt_iptv'; uci set firewall.rt_iptv_upstream.input='REJECT'; uci set firewall.rt_iptv_upstream.output='ACCEPT'; uci set firewall.rt_iptv_upstream.forward='REJECT'; uci set firewall.rt_iptv_upstream.masq='0'
        fw_src='rt_iptv_upstream'
    else
        fw_src='wan'
    fi
    uci set firewall.rt_iptv_igmp_accept='rule'; uci set firewall.rt_iptv_igmp_accept.name='Rostelecom IPTV IGMP upstream'; uci set firewall.rt_iptv_igmp_accept.src="$fw_src"; uci set firewall.rt_iptv_igmp_accept.proto='igmp'; uci set firewall.rt_iptv_igmp_accept.family='ipv4'; uci set firewall.rt_iptv_igmp_accept.target='ACCEPT'
    uci set firewall.rt_iptv_downstream='zone'; uci set firewall.rt_iptv_downstream.name='rt_iptv_lan'; uci add_list firewall.rt_iptv_downstream.network='rt_iptv_lan'; uci set firewall.rt_iptv_downstream.input='ACCEPT'; uci set firewall.rt_iptv_downstream.output='ACCEPT'; uci set firewall.rt_iptv_downstream.forward='REJECT'
    uci set firewall.rt_iptv_igmp_downstream='rule'; uci set firewall.rt_iptv_igmp_downstream.name='Rostelecom IPTV IGMP downstream'; uci set firewall.rt_iptv_igmp_downstream.src='rt_iptv_lan'; uci set firewall.rt_iptv_igmp_downstream.proto='igmp'; uci set firewall.rt_iptv_igmp_downstream.family='ipv4'; uci set firewall.rt_iptv_igmp_downstream.target='ACCEPT'
    uci set firewall.rt_iptv_multicast='rule'; uci set firewall.rt_iptv_multicast.name='Rostelecom IPTV multicast'; uci set firewall.rt_iptv_multicast.src="$fw_src"; uci set firewall.rt_iptv_multicast.dest='rt_iptv_lan'; uci set firewall.rt_iptv_multicast.family='ipv4'; uci set firewall.rt_iptv_multicast.proto='udp'; uci set firewall.rt_iptv_multicast.dest_ip='224.0.0.0/4'; uci set firewall.rt_iptv_multicast.target='ACCEPT'
}
configure_igmpproxy() {
    uci set igmpproxy.rt_iptv_igmp='igmpproxy'; uci set igmpproxy.rt_iptv_igmp.quickleave='1'; uci set igmpproxy.rt_iptv_igmp.verbose='0'
    if [ "$mode_choice_network" = "classic" ]; then
        uci set igmpproxy.rt_iptv_upstream='phyint'; uci set igmpproxy.rt_iptv_upstream.network='wan'; uci set igmpproxy.rt_iptv_upstream.zone='wan'; uci set igmpproxy.rt_iptv_upstream.direction='upstream'
    else
        uci set igmpproxy.rt_iptv_upstream='phyint'; uci set igmpproxy.rt_iptv_upstream.network='rt_iptv'; uci set igmpproxy.rt_iptv_upstream.zone='rt_iptv_upstream'; uci set igmpproxy.rt_iptv_upstream.direction='upstream'
    fi
    for ip in $ALTNETS; do uci add_list igmpproxy.rt_iptv_upstream.altnet="$ip"; done
    uci set igmpproxy.rt_iptv_downstream='phyint'; uci set igmpproxy.rt_iptv_downstream.network='rt_iptv_lan'; uci set igmpproxy.rt_iptv_downstream.zone='rt_iptv_lan'; uci set igmpproxy.rt_iptv_downstream.direction='downstream'
}
install_hotplug() {
    if [ -f "$HOTPLUG_FILE" ] && ! grep -q "$PROJECT" "$HOTPLUG_FILE" 2>/dev/null; then
        cp "$HOTPLUG_FILE" "$HOTPLUG_BACKUP" || die "Не удалось сохранить существующий hotplug-файл."
    fi
    cat > "$HOTPLUG_FILE" <<EOF2
#!/bin/sh
# $PROJECT $VERSION
[ "\$ACTION" = "ifup" ] || exit 0
case "\$INTERFACE" in wan|rt_iptv) /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true ;; esac
exit 0
EOF2
    chmod +x "$HOTPLUG_FILE"
}
remove_hotplug() {
    if [ -f "$HOTPLUG_FILE" ] && grep -q "$PROJECT" "$HOTPLUG_FILE" 2>/dev/null; then
        if [ -f "$HOTPLUG_BACKUP" ]; then
            cp "$HOTPLUG_BACKUP" "$HOTPLUG_FILE" && chmod +x "$HOTPLUG_FILE"
        else
            rm -f "$HOTPLUG_FILE"
        fi
    fi
    rm -f "$HOTPLUG_BACKUP"
}
rollback_project() {
    # Automatic rollback is project-scoped. The explicit `restore` command
    # remains the full-file emergency restore path.
    port="${IPTV_PORT:-}"
    [ -n "$port" ] || port="$(cat "$STATE_DIR/iptv_port" 2>/dev/null || true)"
    /etc/init.d/igmpproxy stop >/dev/null 2>&1 || true
    remove_owned_config
    [ -n "$port" ] && restore_port_membership "$port"
    remove_hotplug
    rm -f "$CONFIG_FILE" "$STATE_DIR/iptv_port"
    uci commit network >/dev/null 2>&1 || true
    uci commit firewall >/dev/null 2>&1 || true
    uci commit dhcp >/dev/null 2>&1 || true
    uci commit igmpproxy >/dev/null 2>&1 || true
    /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true
}
validate() {
    uci show network >/dev/null || die "Ошибка UCI network."
    uci show firewall >/dev/null || die "Ошибка UCI firewall."
    uci show dhcp >/dev/null || die "Ошибка UCI dhcp."
    uci show igmpproxy >/dev/null || die "Ошибка UCI igmpproxy."
    uci -q get network.rt_iptv_lan.device >/dev/null || die "rt_iptv_lan interface не создан."
    if [ "${mode_choice_network:-classic}" = "vlan" ]; then
        uci -q get network.rt_iptv.device >/dev/null || die "VLAN upstream interface не создан."
    else
        uci -q get network.wan >/dev/null || die "WAN interface не найден."
    fi
    uci -q get firewall.rt_iptv_multicast.dest_ip >/dev/null || die "Multicast firewall rule не создан."
}
apply() {
    uci commit network || { rollback_project; die "Не удалось сохранить network. Проект откатан."; }
    uci commit firewall || { rollback_project; die "Не удалось сохранить firewall. Проект откатан."; }
    uci commit dhcp || { rollback_project; die "Не удалось сохранить dhcp. Проект откатан."; }
    uci commit igmpproxy || { rollback_project; die "Не удалось сохранить igmpproxy. Проект откатан."; }
    if ! /etc/init.d/network reload >/dev/null 2>&1; then
        log "Сбой reload network — выполняю проектный откат."
        rollback_project
        die "Network reload завершился ошибкой. Проект откатан."
    fi
    /etc/init.d/firewall reload >/dev/null 2>&1 || { rollback_project; die "Firewall reload завершился ошибкой. Проект откатан."; }
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || { rollback_project; die "Dnsmasq restart завершился ошибкой. Проект откатан."; }
    /etc/init.d/igmpproxy enable >/dev/null 2>&1 || true
    /etc/init.d/igmpproxy restart >/dev/null 2>&1 || { rollback_project; die "igmpproxy не запустился. Проект откатан."; }
}
write_state() {
    mode="$1"; port="$2"; wan="$3"; vid="${4:-}"
    tmp="$CONFIG_FILE.tmp.$$"
    cat > "$tmp" <<EOF2
VERSION=$VERSION
MODE=$mode
IPTV_PORT=$port
WAN_DEVICE=$wan
VLAN_ID=$vid
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
EOF2
    mv "$tmp" "$CONFIG_FILE"
}
post_check() {
    log "\nПроверка после установки..."
    if [ "${mode_choice_network:-classic}" = "vlan" ] && uci -q get network.rt_iptv.device >/dev/null 2>&1; then
        log "✓ IPTV upstream: $(uci_get network.rt_iptv.device)"
    else
        log "✓ IPTV upstream: network.wan"
    fi
    [ -d /sys/class/net/br-rt-iptv ] && log "✓ IPTV bridge: br-rt-iptv" || log "! Bridge ещё не поднялся"
    pidof igmpproxy >/dev/null 2>&1 && log "✓ igmpproxy запущен" || log "! igmpproxy не запущен — запустите diagnose"
    log "\nГотово. Подключите приставку к выбранному IPTV-порту и выполните: $0 status"
}

install_wizard() {
    is_root
    [ ! -f "$CONFIG_FILE" ] || die "IPTV уже установлено. Сначала удалите текущую конфигурацию."
    header
    log "Мастер установки IPTV"
    log ""
    log "Выберите схему подключения, которую подтвердил ваш провайдер:"
    log "  1) Обычная IPTV-схема без VLAN"
    log "  2) VLAN — только если VLAN ID точно известен"
    printf "\nВаш выбор [1]: "
    read -r mode_choice
    case "${mode_choice:-1}" in
        1) install_classic ;;
        2)
            printf "Физический WAN/parent (например eth0): "
            read -r parent
            printf "VLAN ID (1-4094): "
            read -r vid
            printf "IPTV-порт приставки (например lan4): "
            read -r port
            install_vlan_manual "$parent" "$vid" "$port"
            ;;
        *) die "Неизвестный вариант." ;;
    esac
}

install_vlan_manual() {
    is_root
    parent="${1:-}"; vid="${2:-}"; port="${3:-}"
    [ ! -f "$CONFIG_FILE" ] || die "IPTV уже установлено. Сначала выполните uninstall."
    ensure_igmpproxy
    [ -n "$parent" ] && [ -n "$vid" ] && [ -n "$port" ] || die "Не заполнены параметры VLAN."
    [ -e "/sys/class/net/$parent/device" ] || die "Parent должен быть физическим интерфейсом: $parent"
    is_virtual_iface "$parent" && die "Parent не должен быть виртуальным интерфейсом: $parent"
    is_virtual_iface "$port" && die "IPTV-порт должен быть физическим Ethernet-портом: $port"
    validate_vid "$vid" || die "VLAN ID должен быть 1..4094."
    [ -e "/sys/class/net/$port/device" ] || die "IPTV-порт не найден: $port"
    [ "$parent" != "$port" ] || die "Parent и IPTV-порт не могут совпадать."
    assert_project_names_free
    backup before-vlan-install
    save_port_membership "$port"
    printf '%s\n' "$port" > "$STATE_DIR/iptv_port"
    mode_choice_network=vlan
    configure_network "$port" "$parent" vlan "$vid"
    configure_dhcp
    configure_firewall
    configure_igmpproxy
    install_hotplug
    validate
    apply
    if ! write_state vlan "$port" "$parent" "$vid"; then
        restore_backup
        die "Не удалось сохранить состояние проекта. Конфигурация откатана."
    fi
    post_check
}
install_classic() {
    is_root; [ ! -f "$CONFIG_FILE" ] || die "IPTV уже установлено. Сначала выполните uninstall, затем установите заново."; ensure_igmpproxy; select_port; port="$IPTV_PORT"; wan="$(detect_wan_device)"
    uci -q get network.wan >/dev/null 2>&1 || die "Сеть network.wan не найдена."
    assert_project_names_free; backup "before-install"; save_port_membership "$port"; printf '%s\n' "$port" > "$STATE_DIR/iptv_port"; mode_choice_network=classic; configure_network "$port" "$wan" classic; configure_dhcp; configure_firewall; configure_igmpproxy; install_hotplug; validate; apply; if ! write_state classic "$port" "$wan"; then rollback_project; die "Не удалось сохранить состояние проекта. Проект откатан."; fi; post_check
}
install_vlan() {
    install_vlan_manual "${2:-}" "${3:-}" "${4:-}"
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
    is_root; header; log "OpenWrt: $(openwrt_version)"; log "WAN device: $(detect_wan_device)"
    log "WAN network: $(uci_get network.wan.proto)"
    log "\n--- Адреса ---"; ip -br addr 2>/dev/null | grep -E 'rt_iptv|br-rt-iptv|wan|eth|lan' || true
    log "--- Маршруты multicast ---"; ip route 2>/dev/null | grep -E '224\.0\.0\.0|10\.0\.0\.0/24|192\.168\.100\.0/24' || true
    log "--- igmpproxy ---"; pidof igmpproxy 2>/dev/null || log "NOT RUNNING"
    log "--- Настроенные altnet ---"; uci -q show igmpproxy.rt_iptv_upstream.altnet 2>/dev/null || log "altnet не найден"
    log "--- Возможные сообщения о multicast source ---"; logread 2>/dev/null | grep -Ei 'igmpproxy|multicast|source|altnet|not allowed' | tail -n 100 || true
    log "--- /proc/net/igmp ---"; cat /proc/net/igmp 2>/dev/null || true
    command -v fw4 >/dev/null 2>&1 && { log "--- Firewall ---"; fw4 print 2>/dev/null | grep -E 'rt_iptv|224\.0\.0\.0/4|igmpproxy' | tail -n 80 || true; }
}
plan() {
    is_root; header
    wan="$(detect_wan_device)"
    log "WAN device: ${wan:-не определён}"
    log "Физические IPTV-порты:"
    list_ports || true
    log ""
    log "Classic: использует существующую network.wan как upstream; отдельный L3-интерфейс на WAN не создаётся."
    log "VLAN: создаётся только при явно указанном parent + VLAN ID; DSA bridge-vlan автоматически не угадывается."
    log "Изменяются только проектные UCI-секции и выбранный IPTV-порт после backup."
    log "Никаких удалённых конфигураций, WAN MAC или PPPoE credentials проект не меняет."
}
list_ports_cmd() { is_root; log "WAN: $(detect_wan_device)"; log "Физические порты:"; list_ports; }
show_config() { is_root; header; for cfg in network firewall dhcp igmpproxy; do log "--- $cfg ---"; uci show "$cfg" | grep -E 'rt_iptv' || true; done; }
add_altnet() {
    is_root; [ -f "$CONFIG_FILE" ] || die "IPTV не установлено."; value="${1:-}"; [ -n "$value" ] || die "Использование: $0 add-altnet <IPv4[/prefix]>"; valid_altnet "$value" || die "Некорректный IPv4/CIDR: $value"; value="$(normalize_altnet "$value")"
    uci -q get igmpproxy.rt_iptv_upstream >/dev/null || die "Секция igmpproxy upstream не найдена."
    if uci -q show igmpproxy.rt_iptv_upstream.altnet 2>/dev/null | grep -Fq "='$value'"; then log "altnet уже существует: $value"; return 0; fi
    uci add_list igmpproxy.rt_iptv_upstream.altnet="$value"; uci commit igmpproxy || die "Не удалось сохранить altnet."; /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true; log "Добавлен altnet: $value"
}
remove_altnet() {
    is_root; [ -f "$CONFIG_FILE" ] || die "IPTV не установлено."; value="${1:-}"; [ -n "$value" ] || die "Использование: $0 remove-altnet <IPv4[/prefix]>"; valid_altnet "$value" || die "Некорректный IPv4/CIDR: $value"; value="$(normalize_altnet "$value")"
    uci -q get igmpproxy.rt_iptv_upstream >/dev/null || die "Секция igmpproxy upstream не найдена."
    uci del_list igmpproxy.rt_iptv_upstream.altnet="$value" 2>/dev/null || true; uci commit igmpproxy || die "Не удалось сохранить altnet."; /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true; log "Удалён altnet: $value"
}
uninstall() { is_root; backup before-uninstall; /etc/init.d/igmpproxy stop >/dev/null 2>&1 || true; port="$(cat "$STATE_DIR/iptv_port" 2>/dev/null || true)"; remove_owned_config; [ -n "$port" ] && restore_port_membership "$port"; remove_hotplug; uci commit network; uci commit firewall; uci commit dhcp; uci commit igmpproxy; /etc/init.d/network reload >/dev/null 2>&1 || true; /etc/init.d/firewall reload >/dev/null 2>&1 || true; /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true; /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true; rm -f "$CONFIG_FILE" "$STATE_DIR/iptv_port" "$PORTMAP_FILE"; log "Удаление завершено. Backup сохранён: $BACKUP_DIR"; }

show_help() {
cat <<EOF2
OpenWrt IPTV Ростелеком Manager $VERSION

Основные команды:
  $0                    простое меню
  $0 install            установить Classic IPTV
  $0 install-vlan <parent> <vid> <port>  VLAN IPTV
  $0 status              состояние
  $0 plan                показать безопасный план/топологию без изменений
  $0 diagnose            диагностика
  $0 list-ports          физические порты
  $0 show-config         IPTV UCI-конфигурация
  $0 add-altnet <IPv4[/prefix]>   добавить multicast source
  $0 remove-altnet <IPv4[/prefix]> удалить multicast source
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
        printf '\n  1) Установить IPTV (мастер)\n  2) Проверить IPTV\n  3) Диагностика / исправление\n  4) Показать доступные порты\n  5) Показать настройки\n  6) Создать резервную копию\n  7) Удалить IPTV\n  0) Выход\n\nВыберите действие: '
        read -r choice
        case "$choice" in
            1) install_wizard; pause_ui;;
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
    plan) plan;;
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
