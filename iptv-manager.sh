#!/bin/sh
# OpenWrt IPTV Rostelecom Manager
# Independent project - not part of Universal OpenWrt
# Version: 3.0.0
#
# Supports OpenWrt 23.05/24.10 and 25.12+.
# Designed for classic multicast IPTV with a dedicated Ethernet port.
# VLAN-based provider topologies must be configured explicitly.

set -u

VERSION="3.0.0"
PROJECT="iptv-rostelecom"
STATE_DIR="/etc/iptv-rostelecom"
BACKUP_DIR="/root/iptv-rostelecom-backups"
CONFIG_FILE="$STATE_DIR/config"

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

log() { printf '%s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }
is_root() { [ "$(id -u 2>/dev/null)" = "0" ] || die "Запустите скрипт от root."; }

uci_get() { uci -q get "$1" 2>/dev/null; }
uci_del() { uci -q delete "$1" 2>/dev/null || true; }

openwrt_version() {
    [ -r /etc/openwrt_release ] || die "Это не похоже на OpenWrt."
    . /etc/openwrt_release
    printf '%s' "${DISTRIB_RELEASE:-unknown}"
}

pkg_install() {
    if command -v apk >/dev/null 2>&1; then
        apk update >/dev/null 2>&1 || true
        apk add igmpproxy || die "Не удалось установить igmpproxy через apk."
    elif command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 || true
        opkg install igmpproxy || die "Не удалось установить igmpproxy через opkg."
    else
        die "Не найден apk/opkg."
    fi
}

ensure_igmpproxy() {
    command -v igmpproxy >/dev/null 2>&1 && return 0
    log "igmpproxy не найден. Устанавливаю пакет..."
    pkg_install
    command -v igmpproxy >/dev/null 2>&1 || die "igmpproxy после установки не найден."
}

timestamp() {
    date '+%Y%m%d-%H%M%S'
}

backup() {
    tag="${1:-manual}"
    dir="$BACKUP_DIR/$(timestamp)-$tag"
    mkdir -p "$dir"
    for f in network firewall dhcp igmpproxy; do
        [ -f "/etc/config/$f" ] && cp "/etc/config/$f" "$dir/$f"
    done
    printf '%s\n' "$dir" > "$STATE_DIR/last_backup"
    log "Резервная копия: $dir"
}

latest_backup() {
    if [ -r "$STATE_DIR/last_backup" ]; then
        cat "$STATE_DIR/last_backup"
        return 0
    fi
    ls -1dt "$BACKUP_DIR"/* 2>/dev/null | head -n 1
}

restore_backup() {
    dir="$(latest_backup)"
    [ -n "$dir" ] && [ -d "$dir" ] || die "Резервная копия не найдена."
    log "Восстановление из: $dir"
    for f in network firewall dhcp igmpproxy; do
        [ -f "$dir/$f" ] && cp "$dir/$f" "/etc/config/$f"
    done
    uci commit network
    uci commit firewall
    uci commit dhcp
    uci commit igmpproxy
    /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true
    log "Восстановление завершено."
}

detect_wan_device() {
    WAN_DEV="$(uci_get network.wan.device)"
    [ -n "${WAN_DEV:-}" ] || WAN_DEV="$(uci_get network.wan.ifname)"
    [ -n "${WAN_DEV:-}" ] || WAN_DEV="wan"
    printf '%s' "$WAN_DEV"
}

list_ports() {
    for p in /sys/class/net/*; do
        n="${p##*/}"
        case "$n" in
            lo|br-*|docker*|veth*|ppp*|tun*|wg*|wan|eth0|eth1) continue ;;
        esac
        printf '%s\n' "$n"
    done
}

valid_ipv4() {
    echo "$1" | awk -F. '
      NF==4 {
        for(i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
        exit 0
      }
      { exit 1 }'
}

select_port() {
    WAN_DEV="$(detect_wan_device)"
    log ""
    log "WAN device: $WAN_DEV"
    log "Доступные сетевые интерфейсы:"
    ports="$(list_ports)"
    [ -n "$ports" ] || die "Не удалось определить Ethernet-порты."
    printf '%s\n' "$ports"
    log ""
    printf "Введите физический IPTV-порт (например lan4): "
    read -r IPTV_PORT
    [ -n "$IPTV_PORT" ] || die "Порт не указан."
    [ -e "/sys/class/net/$IPTV_PORT" ] || die "Интерфейс $IPTV_PORT не найден."
    [ "$IPTV_PORT" != "$WAN_DEV" ] || die "Нельзя выбрать WAN device как IPTV LAN-порт."
    printf '%s\n' "$IPTV_PORT" > "$STATE_DIR/iptv_port"

    case "$WAN_DEV" in
        *.*|br-*|bond*|@*) 
            log "ВНИМАНИЕ: WAN device выглядит как VLAN/bridge ($WAN_DEV)."
            log "Автоматически угадывать VLAN Ростелекома небезопасно."
            log "Продолжение возможно только если ваш IPTV multicast доступен через этот L2 WAN device."
            printf "Продолжить? [y/N]: "
            read -r ans
            case "$ans" in y|Y|д|Д) ;; *) die "Остановлено пользователем.";; esac
            ;;
    esac
}

remove_port_from_bridges() {
    port="$1"
    for sec in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
        ports="$(uci_get "network.$sec.ports")"
        [ -n "$ports" ] || continue
        new=""
        for item in $ports; do
            [ "$item" = "$port" ] && continue
            if [ -n "$new" ]; then new="$new $item"; else new="$item"; fi
        done
        [ "$new" = "$ports" ] && continue
        uci set "network.$sec.ports=$new"
    done
}

remove_owned_config() {
    # Remove only sections created by this project.
    for sec in rt_iptv_lan rt_iptv_dev rt_iptv; do uci_del "network.$sec"; done

    for sec in rt_iptv_dhcp; do uci_del "dhcp.$sec"; done

    for sec in rt_iptv_igmp; do uci_del "igmpproxy.$sec"; done
    for sec in rt_iptv_upstream rt_iptv_downstream rt_iptv_disabled; do
        uci_del "igmpproxy.$sec"
    done

    for sec in rt_iptv_upstream rt_iptv_downstream rt_iptv_igmp_accept rt_iptv_igmp_downstream rt_iptv_multicast; do
        uci_del "firewall.$sec"
    done
    uci_del firewall.rt_iptv_to_lan

    # Remove this project's IPTV port from pre-existing bridge devices.
    if [ -r "$STATE_DIR/iptv_port" ]; then
        port="$(cat "$STATE_DIR/iptv_port")"
        [ -n "$port" ] && remove_port_from_bridges "$port"
    fi
}

configure_network() {
    port="$1"
    wan_dev="$2"

    remove_owned_config

    # Dedicated IPTV LAN bridge.
    uci set network.rt_iptv_dev='device'
    uci set network.rt_iptv_dev.name='br-rt-iptv'
    uci set network.rt_iptv_dev.type='bridge'
    uci set network.rt_iptv_dev.ports="$port"
    uci set network.rt_iptv_dev.igmp_snooping='1'
    uci set network.rt_iptv_dev.igmpversion='2'

    uci set network.rt_iptv_lan='interface'
    uci set network.rt_iptv_lan.proto='static'
    uci set network.rt_iptv_lan.device='br-rt-iptv'
    uci set network.rt_iptv_lan.ipaddr='192.168.100.1'
    uci set network.rt_iptv_lan.netmask='255.255.255.0'
    uci set network.rt_iptv_lan.delegate='0'

    # IPTV upstream logical interface on the existing WAN L2 device.
    # This follows the topology used by the reference project, but without
    # replacing the user's WAN interface or hard-coding a MAC address.
    uci set network.rt_iptv='interface'
    uci set network.rt_iptv.proto='static'
    uci set network.rt_iptv.device="$wan_dev"
    uci set network.rt_iptv.ipaddr='10.0.0.1'
    uci set network.rt_iptv.netmask='255.255.255.0'
    uci set network.rt_iptv.defaultroute='0'
    uci set network.rt_iptv.peerdns='0'
    uci set network.rt_iptv.delegate='0'
    uci set network.rt_iptv.mtu='1492'

    # Keep WAN untouched by default. Optional PPPoE setup is offered separately.
}

configure_dhcp() {
    uci set dhcp.rt_iptv_dhcp='dhcp'
    uci set dhcp.rt_iptv_dhcp.interface='rt_iptv_lan'
    uci set dhcp.rt_iptv_dhcp.start='100'
    uci set dhcp.rt_iptv_dhcp.limit='150'
    uci set dhcp.rt_iptv_dhcp.leasetime='12h'
    uci set dhcp.rt_iptv_dhcp.force='1'
}

configure_firewall() {
    # Dedicated zones: do not assume interface names are firewall zones.
    uci set firewall.rt_iptv_upstream='zone'
    uci set firewall.rt_iptv_upstream.name='iptv'
    uci set firewall.rt_iptv_upstream.network='rt_iptv'
    uci set firewall.rt_iptv_upstream.input='REJECT'
    uci set firewall.rt_iptv_upstream.output='ACCEPT'
    uci set firewall.rt_iptv_upstream.forward='REJECT'
    uci set firewall.rt_iptv_upstream.masq='0'

    uci set firewall.rt_iptv_downstream='zone'
    uci set firewall.rt_iptv_downstream.name='iptv_lan'
    uci set firewall.rt_iptv_downstream.network='rt_iptv_lan'
    uci set firewall.rt_iptv_downstream.input='ACCEPT'
    uci set firewall.rt_iptv_downstream.output='ACCEPT'
    uci set firewall.rt_iptv_downstream.forward='REJECT'

    uci set firewall.rt_iptv_to_lan='forwarding'
    uci set firewall.rt_iptv_to_lan.src='iptv'
    uci set firewall.rt_iptv_to_lan.dest='iptv_lan'

    uci set firewall.rt_iptv_igmp_accept='rule'
    uci set firewall.rt_iptv_igmp_accept.name='Rostelecom IPTV IGMP upstream'
    uci set firewall.rt_iptv_igmp_accept.src='iptv'
    uci set firewall.rt_iptv_igmp_accept.proto='igmp'
    uci set firewall.rt_iptv_igmp_accept.family='ipv4'
    uci set firewall.rt_iptv_igmp_accept.target='ACCEPT'

    uci set firewall.rt_iptv_igmp_downstream='rule'
    uci set firewall.rt_iptv_igmp_downstream.name='Rostelecom IPTV IGMP downstream'
    uci set firewall.rt_iptv_igmp_downstream.src='iptv_lan'
    uci set firewall.rt_iptv_igmp_downstream.proto='igmp'
    uci set firewall.rt_iptv_igmp_downstream.family='ipv4'
    uci set firewall.rt_iptv_igmp_downstream.target='ACCEPT'

    uci set firewall.rt_iptv_multicast='rule'
    uci set firewall.rt_iptv_multicast.name='Rostelecom IPTV multicast'
    uci set firewall.rt_iptv_multicast.src='iptv'
    uci set firewall.rt_iptv_multicast.dest='iptv_lan'
    uci set firewall.rt_iptv_multicast.family='ipv4'
    uci set firewall.rt_iptv_multicast.proto='udp'
    uci set firewall.rt_iptv_multicast.dest_ip='224.0.0.0/4'
    uci set firewall.rt_iptv_multicast.target='ACCEPT'
}

configure_igmpproxy() {
    # Known source networks from the reference project. These are not claimed
    # to be universal; add regional source IPs with: add-altnet <IPv4>.
    uci set igmpproxy.rt_iptv_igmp='igmpproxy'
    uci set igmpproxy.rt_iptv_igmp.quickleave='1'

    uci set igmpproxy.rt_iptv_upstream='phyint'
    uci set igmpproxy.rt_iptv_upstream.network='rt_iptv'
    uci set igmpproxy.rt_iptv_upstream.direction='upstream'
    for ip in \
        198.18.20.5 \
        10.179.47.27 \
        10.171.151.11 \
        212.12.12.235 \
        212.12.12.234 \
        212.193.149.193 \
        212.193.157.250 \
        46.235.189.194 \
        195.209.81.195 \
        212.193.155.254 \
        212.193.153.129 \
        212.193.155.240 \
        65.9.46.41
    do
        uci add_list igmpproxy.rt_iptv_upstream.altnet="$ip"
    done

    uci set igmpproxy.rt_iptv_downstream='phyint'
    uci set igmpproxy.rt_iptv_downstream.network='rt_iptv_lan'
    uci set igmpproxy.rt_iptv_downstream.direction='downstream'
}

optional_pppoe() {
    log ""
    log "Текущий WAN proto: $(uci_get network.wan.proto)"
    printf "Нужно настроить WAN как PPPoE? [y/N]: "
    read -r ans
    case "$ans" in
        y|Y|д|Д)
            printf "PPPoE логин: "
            read -r user
            printf "PPPoE пароль: "
            stty -echo 2>/dev/null || true
            read -r pass
            stty echo 2>/dev/null || true
            printf '\n'
            [ -n "$user" ] || die "PPPoE логин пуст."
            uci set network.wan.proto='pppoe'
            uci set network.wan.username="$user"
            uci set network.wan.password="$pass"
            uci set network.wan.mtu='1492'
            uci set network.wan.keepalive='5 10'
            ;;
    esac
}

validate() {
    log "Проверяю UCI-конфигурацию..."
    uci show network >/dev/null || die "Ошибка UCI network."
    uci show firewall >/dev/null || die "Ошибка UCI firewall."
    uci show dhcp >/dev/null || die "Ошибка UCI dhcp."
    uci show igmpproxy >/dev/null || die "Ошибка UCI igmpproxy."
}

apply() {
    uci commit network
    uci commit firewall
    uci commit dhcp
    uci commit igmpproxy

    log "Перезагрузка сетевых служб..."
    /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    /etc/init.d/igmpproxy enable >/dev/null 2>&1 || true
    /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true
}

install() {
    is_root
    ver="$(openwrt_version)"
    log "OpenWrt IPTV Rostelecom Manager $VERSION"
    log "OpenWrt: $ver"

    ensure_igmpproxy
    select_port
    port="$(cat "$STATE_DIR/iptv_port")"
    wan_dev="$(detect_wan_device)"

    # Back up the pre-install configuration. Do not overwrite this backup
    # during uninstall; it remains the rollback point.
    backup "before-install"

    configure_network "$port" "$wan_dev"
    configure_dhcp
    configure_firewall
    configure_igmpproxy

    # Optional and explicit: only change WAN credentials if user asks.
    optional_pppoe

    validate
    apply

    cat > "$CONFIG_FILE" <<EOF
VERSION=$VERSION
IPTV_PORT=$port
WAN_DEVICE=$wan_dev
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    log ""
    log "Установка завершена."
    log "IPTV LAN: 192.168.100.1/24"
    log "DHCP: 192.168.100.100-249"
    log "Порт: $port"
    log "WAN device: $wan_dev"
    log "Проверка: $0 status"
}

status() {
    is_root
    log "=== OpenWrt IPTV Rostelecom $VERSION ==="
    log "--- Project state ---"
    [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || log "Конфигурация проекта не найдена."
    log ""
    log "--- Network ---"
    uci show network.rt_iptv 2>/dev/null || true
    uci show network.rt_iptv_lan 2>/dev/null || true
    uci show network.rt_iptv_dev 2>/dev/null || true
    log ""
    log "--- DHCP ---"
    uci show dhcp.rt_iptv_dhcp 2>/dev/null || true
    log ""
    log "--- Firewall ---"
    uci show firewall | grep -E 'rt_iptv' 2>/dev/null || true
    log ""
    log "--- IGMP proxy ---"
    uci show igmpproxy | grep -E 'rt_iptv' 2>/dev/null || true
    log ""
    log "--- Processes ---"
    pgrep igmpproxy 2>/dev/null || log "igmpproxy process not found."
    log ""
    log "--- Recent IGMP logs ---"
    logread 2>/dev/null | grep -i igmp | tail -n 30 || true
}

add_altnet() {
    is_root
    ip="${1:-}"
    [ -n "$ip" ] || die "Использование: $0 add-altnet 212.12.12.236"
    valid_ipv4 "$ip" || die "Некорректный IPv4: $ip"
    uci add_list igmpproxy.rt_iptv_upstream.altnet="$ip"
    uci commit igmpproxy
    /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true
    log "Добавлен altnet: $ip"
}

uninstall() {
    is_root
    log "Удаляю только конфигурацию, созданную этим проектом."
    log "Существующие пользовательские конфиги не заменяются."
    remove_owned_config
    uci commit network
    uci commit firewall
    uci commit dhcp
    uci commit igmpproxy
    /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true
    rm -f "$CONFIG_FILE"
    log "Удаление завершено."
    log "Если нужен полный откат к состоянию до установки: $0 restore"
}

show_help() {
    cat <<EOF
OpenWrt IPTV Rostelecom Manager $VERSION

Использование:
  $0 install
  $0 status
  $0 add-altnet <IPv4>
  $0 restore
  $0 uninstall
  $0 help

Команды:
  install       Установить IPTV-конфигурацию.
  status        Показать состояние network/firewall/dhcp/igmpproxy.
  add-altnet    Добавить региональный multicast source IP.
  restore       Восстановить последнюю резервную копию.
  uninstall     Удалить только секции этого проекта.
EOF
}

cmd="${1:-install}"
case "$cmd" in
    install) install ;;
    status) status ;;
    add-altnet) add_altnet "${2:-}" ;;
    restore) is_root; restore_backup ;;
    uninstall) uninstall ;;
    help|-h|--help) show_help ;;
    *) die "Неизвестная команда: $cmd. Используйте: $0 help" ;;
esac
