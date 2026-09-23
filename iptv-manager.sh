#!/bin/sh
# OpenWrt IPTV Rostelecom Manager
# Independent project - NOT part of Universal OpenWrt
# Version: 5.5.0
# Clean rebuild: transactional UCI, topology safety, diagnostics, rollback, shared-WAN safety.

set -u

VERSION="5.5.0"
PROJECT="iptv-rostelecom"
STATE_DIR="/etc/iptv-rostelecom"
BACKUP_DIR="/root/iptv-rostelecom-backups"
CONFIG_FILE="$STATE_DIR/config"
PORTMAP_FILE="$STATE_DIR/portmap"
HOTPLUG_FILE="/etc/hotplug.d/iface/99-iptv-rostelecom"
HOTPLUG_BACKUP="$STATE_DIR/original-hotplug"
LOCK_DIR="/var/run/iptv-rostelecom.lock"
SERVICE_STATE_DIR="$STATE_DIR/service"

# Starting source allow-list observed in the independent Rostelecom reference.
# It is NOT universal; use add-altnet/remove-altnet for your region.
DEFAULT_ALTNETS="198.18.20.5/32 10.179.47.27/32 10.171.151.11/32 212.12.12.235/32 212.12.12.234/32 212.193.149.193/32 212.193.157.250/32 46.235.189.194/32 195.209.81.195/32 212.193.155.254/32 212.193.153.129/32 212.193.155.240/32 65.9.46.41/32"

TX_ACTIVE=0
TX_PORT=""
TX_BACKUP_DIR=""

log() { printf '%s\n' "$*"; }
warn() { printf 'ПРЕДУПРЕЖДЕНИЕ: %s\n' "$*"; }
die() {
    log ""
    log "ОШИБКА: $*"
    if [ "$TX_ACTIVE" = "1" ]; then
        rollback_transaction || warn "Автоматический rollback завершился с дополнительной ошибкой."
    fi
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

require_openwrt() {
    [ -r /etc/openwrt_release ] || die "Это не похоже на OpenWrt: /etc/openwrt_release отсутствует."
    require_cmd uci
    require_cmd ip
    require_cmd awk
    require_cmd sed
    require_cmd grep
    require_cmd tr
    require_cmd cp
    require_cmd mv
    require_cmd rm
    require_cmd mkdir
    require_cmd date
    require_cmd sort
    require_cmd tail
}

is_root() {
    [ "$(id -u 2>/dev/null)" = "0" ] || die "Запустите скрипт от root."
    require_openwrt
    mkdir -p "$STATE_DIR" "$BACKUP_DIR" || die "Не удалось создать каталоги состояния."
}

uci_get() { uci -q get "$1" 2>/dev/null; }
uci_has() { uci -q get "$1" >/dev/null 2>&1; }
uci_del() { uci -q delete "$1" >/dev/null 2>&1 || true; }
uci_del_list_all() {
    section="$1"; option="$2"; value="$3"
    while uci -q del_list "$section.$option=$value" >/dev/null 2>&1; do :; done
}
uci_list_values() {
    section="$1"; option="$2"
    uci -q show "$section.$option" 2>/dev/null | sed -n "s/^[^=]*='\(.*\)'$/\1/p"
}

uci_is_clean() {
    [ -z "$(uci changes 2>/dev/null)" ]
}

require_clean_uci() {
    if ! uci_is_clean; then
        log ""
        log "Обнаружены несохранённые изменения UCI:"
        uci changes 2>/dev/null || true
        die "Сначала сохраните или отмените изменения UCI. IPTV Manager не вмешивается в незавершённую конфигурацию."
    fi
}

service_enabled() {
    [ -e /etc/rc.d/S??igmpproxy ]
}

service_running() {
    if command -v pidof >/dev/null 2>&1 && pidof igmpproxy >/dev/null 2>&1; then return 0; fi
    [ -x /etc/init.d/igmpproxy ] && /etc/init.d/igmpproxy status >/dev/null 2>&1
}

save_service_state() {
    mkdir -p "$SERVICE_STATE_DIR" || return 1
    if service_enabled; then printf '1\n' > "$SERVICE_STATE_DIR/enabled"; else printf '0\n' > "$SERVICE_STATE_DIR/enabled"; fi
    if service_running; then printf '1\n' > "$SERVICE_STATE_DIR/running"; else printf '0\n' > "$SERVICE_STATE_DIR/running"; fi
}

restore_service_state() {
    enabled="$(cat "$SERVICE_STATE_DIR/enabled" 2>/dev/null || printf '0')"
    running="$(cat "$SERVICE_STATE_DIR/running" 2>/dev/null || printf '0')"
    [ -x /etc/init.d/igmpproxy ] || { [ "$enabled" = "0" ] && [ "$running" = "0" ]; } || return 1
    if [ "$enabled" = "1" ]; then
        /etc/init.d/igmpproxy enable >/dev/null 2>&1 || return 1
    else
        /etc/init.d/igmpproxy disable >/dev/null 2>&1 || return 1
    fi
    if [ "$running" = "1" ]; then
        /etc/init.d/igmpproxy restart >/dev/null 2>&1 || return 1
    else
        /etc/init.d/igmpproxy stop >/dev/null 2>&1 || true
    fi
}


confirm() {
    printf '%s [y/N]: ' "$1"
    read -r answer
    case "$answer" in
        y|Y|д|Д) return 0 ;;
        *) return 1 ;;
    esac
}

openwrt_version() {
    # shellcheck disable=SC1091
    . /etc/openwrt_release
    printf '%s' "${DISTRIB_RELEASE:-unknown}"
}

lock_acquire() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return 0
    fi
    old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        die "Другой экземпляр менеджера уже выполняется (PID $old_pid)."
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null || die "Не удалось удалить устаревшую блокировку $LOCK_DIR."
    mkdir "$LOCK_DIR" 2>/dev/null || die "Не удалось создать блокировку $LOCK_DIR."
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

lock_release() {
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

cleanup() {
    lock_release
}
trap cleanup EXIT INT TERM

# -----------------------------
# Network topology
# -----------------------------

detect_wan_device() {
    wan="$(uci_get network.wan.device)"
    if [ -z "$wan" ]; then
        wan="$(uci_get network.wan.ifname)"
    fi
    printf '%s' "$wan"
}

detect_wan_proto() {
    uci_get network.wan.proto
}

is_virtual_iface() {
    case "$1" in
        lo|br-*|docker*|veth*|ppp*|tun*|wg*|sit*|gre*|ip6tnl*|bond*|dummy*|ifb*) return 0 ;;
        *) return 1 ;;
    esac
}

is_physical_port() {
    port="$1"
    validate_port_name "$port" || return 1
    [ -e "/sys/class/net/$port/device" ] || return 1
    is_virtual_iface "$port" && return 1
    return 0
}

validate_port_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

port_link_state() {
    port="$1"
    if [ -r "/sys/class/net/$port/carrier" ]; then
        if [ "$(cat "/sys/class/net/$port/carrier" 2>/dev/null)" = "1" ]; then
            printf 'подключён'
        else
            printf 'не подключён'
        fi
    elif [ -r "/sys/class/net/$port/operstate" ]; then
        cat "/sys/class/net/$port/operstate"
    else
        printf 'неизвестно'
    fi
}

network_device_sections() {
    uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'
}

device_section_by_name() {
    wanted="$1"
    while IFS= read -r sec; do
        [ -n "$sec" ] || continue
        name="$(uci_get "network.$sec.name")"
        [ "$name" = "$wanted" ] && { printf '%s' "$sec"; return 0; }
    done <<EOF2
$(network_device_sections)
EOF2
    return 1
}

device_ports() {
    sec="$1"
    uci_get "network.$sec.ports"
}
network_bridge_vlan_sections() {
    uci show network 2>/dev/null | sed -n 's/^network\.\([^=]*\)=bridge-vlan$/\1/p'
}

bridge_vlan_device() { uci_get "network.$1.device"; }
bridge_vlan_ports() { uci_get "network.$1.ports"; }

port_bridge_vlan_membership() {
    port="$1"; found=""
    while IFS= read -r sec; do
        [ -n "$sec" ] || continue
        ports="$(bridge_vlan_ports "$sec")"
        for item in $ports; do
            base="${item%%:*}"
            [ "$base" = "$port" ] || continue
            dev="$(bridge_vlan_device "$sec")"
            found="${found}${found:+, }${dev:-$sec}:$item"
            break
        done
    done <<EOF2
$(network_bridge_vlan_sections)
EOF2
    [ -n "$found" ] && printf '%s' "$found" || printf 'нет'
}

bridge_vlan_contains_port() {
    port="$1"
    while IFS= read -r sec; do
        [ -n "$sec" ] || continue
        ports="$(bridge_vlan_ports "$sec")"
        for item in $ports; do
            [ "${item%%:*}" = "$port" ] && return 0
        done
    done <<EOF2
$(network_bridge_vlan_sections)
EOF2
    return 1
}


# Recursive enough for normal OpenWrt bridge nesting; deliberately bounded.
device_contains_port() {
    device="$1"
    target="$2"
    depth="${3:-0}"

    [ "$depth" -le 8 ] || return 1
    [ -n "$device" ] || return 1
    [ "$device" = "$target" ] && return 0

    base="${device%%.*}"
    sec="$(device_section_by_name "$base" 2>/dev/null || true)"
    [ -n "$sec" ] || return 1

    ports="$(device_ports "$sec")"
    for item in $ports; do
        [ "$item" = "$target" ] && return 0
        if [ "$item" != "$device" ]; then
            if device_contains_port "$item" "$target" $((depth + 1)); then
                return 0
            fi
        fi
    done
    return 1
}

port_in_wan_path() {
    port="$1"
    wan="$(detect_wan_device)"
    [ -n "$wan" ] || return 1
    [ "$port" = "$wan" ] && return 0
    base="${wan%%.*}"
    [ "$port" = "$base" ] && return 0
    device_contains_port "$wan" "$port" 0 && return 0
    [ "$base" != "$wan" ] && device_contains_port "$base" "$port" 0
}

port_bridge_membership() {
    port="$1"
    found=""
    while IFS= read -r sec; do
        [ -n "$sec" ] || continue
        ports="$(uci_get "network.$sec.ports")"
        case " $ports " in
            *" $port "*)
                name="$(uci_get "network.$sec.name")"
                found="${found}${found:+, }${name:-$sec}"
                ;;
        esac
    done <<EOF2
$(network_device_sections)
EOF2
    [ -n "$found" ] && printf '%s' "$found" || printf 'нет'
}

is_dsa_system() {
    for uevent in /sys/class/net/*/uevent; do
        [ -r "$uevent" ] || continue
        grep -q '^DEVTYPE=dsa$' "$uevent" 2>/dev/null && return 0
    done
    return 1
}

list_physical_ports() {
    for path in /sys/class/net/*; do
        name="${path##*/}"
        is_physical_port "$name" || continue
        printf '%s\n' "$name"
    done | sort
}

list_ports() {
    is_root
    wan="$(detect_wan_device)"
    log "WAN device: ${wan:-не определён}"
    log "WAN proto:  $(detect_wan_proto || true)"
    if is_dsa_system; then
        log "DSA:        обнаружен"
    else
        log "DSA:        не обнаружен/не определён"
    fi
    log ""
    log "Физические порты:"
    ports="$(list_physical_ports)"
    [ -n "$ports" ] || die "Физические Ethernet-порты не найдены."
    printf '%s\n' "$ports" | while IFS= read -r port; do
        [ -n "$port" ] || continue
        if port_in_wan_path "$port"; then
            role="ЗАЩИЩЁН: WAN/management path"
        else
            role="доступен"
        fi
        printf '  %-12s link=%-14s bridge=%-20s %s\n' "$port" "$(port_link_state "$port")" "$(port_bridge_membership "$port")" "$role"
    done
}

# -----------------------------
# Validation / state
# -----------------------------

valid_ipv4() {
    echo "$1" | awk -F. 'NF==4 {for(i=1;i<=4;i++){if($i !~ /^[0-9]+$/ || $i<0 || $i>255) exit 1} exit 0} {exit 1}'
}

valid_altnet() {
    value="$1"
    case "$value" in
        */*) ipaddr="${value%/*}"; prefix="${value#*/}" ;;
        *) ipaddr="$value"; prefix="32" ;;
    esac
    valid_ipv4 "$ipaddr" || return 1
    echo "$prefix" | awk '$0 ~ /^[0-9]+$/ && $1>=0 && $1<=32 {exit 0} {exit 1}'
}

normalize_altnet() {
    case "$1" in
        */*) printf '%s' "$1" ;;
        *) printf '%s/32' "$1" ;;
    esac
}

validate_vid() {
    echo "$1" | awk '$0 ~ /^[0-9]+$/ && $1>=1 && $1<=4094 {exit 0} {exit 1}'
}

validate_igmp_version() {
    case "$1" in 1|2|3) return 0;; *) return 1;; esac
}

project_installed() {
    [ -f "$CONFIG_FILE" ]
}

assert_project_names_free() {
    for key in \
        network.rt_iptv_dev network.rt_iptv_lan network.rt_iptv_vlan network.rt_iptv_upstream network.rt_iptv network.rt_iptv_dsa \
        dhcp.rt_iptv_dhcp \
        firewall.rt_iptv_upstream firewall.rt_iptv_downstream firewall.rt_iptv_igmp_upstream \
        firewall.rt_iptv_igmp_downstream firewall.rt_iptv_dhcp firewall.rt_iptv_dns firewall.rt_iptv_multicast \
        igmpproxy.rt_iptv igmpproxy.rt_iptv_upstream igmpproxy.rt_iptv_downstream; do
        if uci_has "$key"; then
            die "Обнаружена чужая UCI-секция $key. Сначала удалите конфликт вручную или используйте другой роутер."
        fi
    done
}

write_state() {
    mode="$1"
    port="$2"
    parent="$3"
    vid="$4"
    altnets="$5"
    umask 077
    tmp="$CONFIG_FILE.tmp.$$"
    {
        printf 'version=%s\n' "$VERSION"
        printf 'mode=%s\n' "$mode"
        printf 'port=%s\n' "$port"
        printf 'parent=%s\n' "$parent"
        printf 'vid=%s\n' "$vid"
        printf 'altnets=%s\n' "$altnets"
    } > "$tmp" || die "Не удалось записать состояние проекта."
    mv "$tmp" "$CONFIG_FILE" || die "Не удалось сохранить состояние проекта."
}

state_get() {
    key="$1"
    [ -r "$CONFIG_FILE" ] || return 1
    sed -n "s/^${key}=//p" "$CONFIG_FILE" | tail -n 1
}

# -----------------------------
# Backup / port membership
# -----------------------------

timestamp() { date '+%Y%m%d-%H%M%S'; }

backup_create() {
    tag="${1:-manual}"
    dir="$BACKUP_DIR/$(timestamp)-$tag-$$"
    mkdir -p "$dir" || die "Не удалось создать backup: $dir"
    ok=1
    for cfg in network firewall dhcp igmpproxy; do
        if [ -f "/etc/config/$cfg" ]; then cp -p "/etc/config/$cfg" "$dir/$cfg" || ok=0; else : > "$dir/$cfg.missing" || ok=0; fi
    done
    for pair in "hotplug:$HOTPLUG_FILE" "portmap:$PORTMAP_FILE" "config:$CONFIG_FILE" "altnets:$STATE_DIR/altnets" "service_enabled:$SERVICE_STATE_DIR/enabled" "service_running:$SERVICE_STATE_DIR/running" "original-hotplug:$HOTPLUG_BACKUP"; do
        name="${pair%%:*}"; src="${pair#*:}"
        if [ -f "$src" ]; then cp -p "$src" "$dir/$name" || ok=0; else : > "$dir/$name.missing" || ok=0; fi
    done
    printf '%s\n' 'IPTV-ROSTELECOM-BACKUP-1' > "$dir/MANIFEST" || ok=0
    for f in "$dir"/*; do
        [ "${f##*/}" = "MANIFEST" ] && continue
        [ -f "$f" ] || continue
        sha256sum "$f" >> "$dir/MANIFEST" 2>/dev/null || { cksum "$f" >> "$dir/MANIFEST" 2>/dev/null || true; }
    done
    if [ "$ok" != 1 ]; then rm -rf "$dir"; die "Не удалось полностью создать backup."; fi
    printf '%s\n' "$dir" > "$STATE_DIR/last_backup"
    TX_BACKUP_DIR="$dir"
    log "Backup: $dir"
}

latest_backup() {
    if [ -r "$STATE_DIR/last_backup" ]; then
        dir="$(cat "$STATE_DIR/last_backup")"
        [ -d "$dir" ] && { printf '%s' "$dir"; return 0; }
    fi
    for dir in "$BACKUP_DIR"/*; do
        [ -d "$dir" ] || continue
        printf '%s\n' "$dir"
    done | sort | tail -n 1
}

save_port_membership() {
    port="$1"
    tmp="$PORTMAP_FILE.tmp.$$"
    : > "$tmp" || die "Не удалось создать portmap."
    {
        while IFS= read -r sec; do
            [ -n "$sec" ] || continue
            name="$(uci_get "network.$sec.name")"
            ports="$(uci_get "network.$sec.ports")"
            [ -n "$name" ] || continue
            for item in $ports; do
                [ "$item" = "$port" ] && printf 'device\t%s\t%s\n' "$name" "$ports" && break
            done
        done <<EOF2
$(network_device_sections)
EOF2
        while IFS= read -r sec; do
            [ -n "$sec" ] || continue
            dev="$(bridge_vlan_device "$sec")"
            ports="$(bridge_vlan_ports "$sec")"
            for item in $ports; do
                if [ "${item%%:*}" = "$port" ]; then
                    printf 'bridge-vlan\t%s\t%s\t%s\n' "$sec" "$dev" "$ports"
                    break
                fi
            done
        done <<EOF2
$(network_bridge_vlan_sections)
EOF2
    } > "$tmp" || { rm -f "$tmp"; die "Не удалось сохранить исходное членство порта."; }
    mv "$tmp" "$PORTMAP_FILE" || die "Не удалось сохранить исходное членство порта."
}

restore_port_membership() {
    port="$1"
    [ -r "$PORTMAP_FILE" ] || return 0
    while IFS="$(printf '\t')" read -r kind a b c; do
        [ -n "$kind" ] || continue
        if [ "$kind" = "device" ]; then
            sec="$(device_section_by_name "$a" 2>/dev/null || true)"
            [ -n "$sec" ] || continue
            uci_del_list_all "network.$sec" ports "$port"
            for item in $b; do uci add_list "network.$sec.ports=$item" || return 1; done
        elif [ "$kind" = "bridge-vlan" ]; then
            sec="$a"; uci -q show "network.$sec" >/dev/null 2>&1 || continue
            uci_del_list_all "network.$sec" ports "$port"
            uci_del_list_all "network.$sec" ports "$port:u"
            uci_del_list_all "network.$sec" ports "$port:u*"
            for item in $c; do uci add_list "network.$sec.ports=$item" || return 1; done
        fi
    done < "$PORTMAP_FILE"
    return 0
}

remove_port_from_bridges() {
    port="$1"
    while IFS= read -r sec; do
        [ -n "$sec" ] || continue
        ports="$(uci_get "network.$sec.ports")"
        for item in $ports; do
            [ "$item" = "$port" ] && uci del_list "network.$sec.ports=$item" || true
        done
    done <<EOF2
$(network_device_sections)
EOF2
    while IFS= read -r sec; do
        [ -n "$sec" ] || continue
        ports="$(bridge_vlan_ports "$sec")"
        for item in $ports; do
            [ "${item%%:*}" = "$port" ] && uci del_list "network.$sec.ports=$item" || true
        done
    done <<EOF2
$(network_bridge_vlan_sections)
EOF2
    return 0
}

# -----------------------------
# UCI configuration builders
# -----------------------------

remove_project_uci() {
    for sec in rt_iptv_dev rt_iptv_lan rt_iptv_vlan rt_iptv_upstream rt_iptv; do
        uci_del "network.$sec"
    done
    uci_del network.rt_iptv_dsa
    uci_del dhcp.rt_iptv_dhcp
    for sec in rt_iptv rt_iptv_upstream rt_iptv_downstream; do
        uci_del "igmpproxy.$sec"
    done
    for sec in rt_iptv_upstream rt_iptv_downstream rt_iptv_igmp_upstream rt_iptv_igmp_downstream rt_iptv_dhcp rt_iptv_dns rt_iptv_multicast; do
        uci_del "firewall.$sec"
    done
}

configure_network_classic() {
    port="$1"
    uci set network.rt_iptv_dev='device' || return 1
    uci set network.rt_iptv_dev.name='br-rt-iptv' || return 1
    uci set network.rt_iptv_dev.type='bridge' || return 1
    uci add_list network.rt_iptv_dev.ports="$port" || return 1
    uci set network.rt_iptv_dev.igmp_snooping='1' || return 1

    uci set network.rt_iptv_lan='interface' || return 1
    uci set network.rt_iptv_lan.proto='static' || return 1
    uci set network.rt_iptv_lan.device='br-rt-iptv' || return 1
    uci set network.rt_iptv_lan.ipaddr='192.168.100.1' || return 1
    uci set network.rt_iptv_lan.netmask='255.255.255.0' || return 1
    uci set network.rt_iptv_lan.delegate='0' || return 1
}

configure_network_shared_wan() {
    parent="$1"
    port="$2"

    is_physical_port "$parent" || return 1
    [ "$parent" != "$port" ] || return 1

    uci set network.rt_iptv_dev='device' || return 1
    uci set network.rt_iptv_dev.name='br-rt-iptv' || return 1
    uci set network.rt_iptv_dev.type='bridge' || return 1
    uci add_list network.rt_iptv_dev.ports="$port" || return 1
    uci set network.rt_iptv_dev.igmp_snooping='1' || return 1

    uci set network.rt_iptv_lan='interface' || return 1
    uci set network.rt_iptv_lan.proto='static' || return 1
    uci set network.rt_iptv_lan.device='br-rt-iptv' || return 1
    uci set network.rt_iptv_lan.ipaddr='192.168.100.1' || return 1
    uci set network.rt_iptv_lan.netmask='255.255.255.0' || return 1
    uci set network.rt_iptv_lan.delegate='0' || return 1

    # Shared-WAN IPTV: no DHCP/IP is created on the provider-facing port.
    # The physical parent is exposed to igmpproxy as a proto=none interface.
    uci set network.rt_iptv_upstream='interface' || return 1
    uci set network.rt_iptv_upstream.proto='none' || return 1
    uci set network.rt_iptv_upstream.device="$parent" || return 1
}

configure_network_dsa() {
    bridge="$1"
    vid="$2"
    port="$3"

    is_dsa_system || return 1
    [ -n "$bridge" ] || return 1
    [ -n "$vid" ] || return 1
    [ -n "$port" ] || return 1

    # The safe DSA profile only operates on an existing bridge that already
    # carries the provider WAN. It never invents CPU/DSA topology.
    bridge_sec="$(device_section_by_name "$bridge" 2>/dev/null || true)"
    [ -n "$bridge_sec" ] || return 1
    device_ports "$bridge_sec" | tr ' ' '\n' | grep -Fx "$port" >/dev/null 2>&1 || return 1
    wan="$(detect_wan_device)"
    device_contains_port "$bridge" "$wan" 0 || [ "$wan" = "$bridge" ] || return 1

    uci set network.rt_iptv_dsa='bridge-vlan' || return 1
    uci set network.rt_iptv_dsa.device="$bridge" || return 1
    uci set network.rt_iptv_dsa.vlan="$vid" || return 1
    uci add_list network.rt_iptv_dsa.ports="$port:u*" || return 1
    uci add_list network.rt_iptv_dsa.ports="$bridge:t" || return 1

    uci set network.rt_iptv_dev='device' || return 1
    uci set network.rt_iptv_dev.name="$bridge.$vid" || return 1

    uci set network.rt_iptv_lan='interface' || return 1
    uci set network.rt_iptv_lan.proto='static' || return 1
    uci set network.rt_iptv_lan.device="$bridge.$vid" || return 1
    uci set network.rt_iptv_lan.ipaddr='192.168.100.1' || return 1
    uci set network.rt_iptv_lan.netmask='255.255.255.0' || return 1
    uci set network.rt_iptv_lan.delegate='0' || return 1
}

configure_network_vlan() {
    parent="$1"
    vid="$2"
    port="$3"

    uci set network.rt_iptv_dev='device' || return 1
    uci set network.rt_iptv_dev.name='br-rt-iptv' || return 1
    uci set network.rt_iptv_dev.type='bridge' || return 1
    uci add_list network.rt_iptv_dev.ports="$port" || return 1
    uci set network.rt_iptv_dev.igmp_snooping='1' || return 1

    uci set network.rt_iptv_lan='interface' || return 1
    uci set network.rt_iptv_lan.proto='static' || return 1
    uci set network.rt_iptv_lan.device='br-rt-iptv' || return 1
    uci set network.rt_iptv_lan.ipaddr='192.168.100.1' || return 1
    uci set network.rt_iptv_lan.netmask='255.255.255.0' || return 1
    uci set network.rt_iptv_lan.delegate='0' || return 1

    uci set network.rt_iptv_vlan='device' || return 1
    uci set network.rt_iptv_vlan.name="$parent.$vid" || return 1
    uci set network.rt_iptv_vlan.type='8021q' || return 1
    uci set network.rt_iptv_vlan.ifname="$parent" || return 1
    uci set network.rt_iptv_vlan.vid="$vid" || return 1

    uci set network.rt_iptv='interface' || return 1
    uci set network.rt_iptv.proto='dhcp' || return 1
    uci set network.rt_iptv.device="$parent.$vid" || return 1
    uci set network.rt_iptv.defaultroute='0' || return 1
    uci set network.rt_iptv.peerdns='0' || return 1
    uci set network.rt_iptv.delegate='0' || return 1
}

configure_dhcp() {
    uci set dhcp.rt_iptv_dhcp='dhcp' || return 1
    uci set dhcp.rt_iptv_dhcp.interface='rt_iptv_lan' || return 1
    uci set dhcp.rt_iptv_dhcp.start='100' || return 1
    uci set dhcp.rt_iptv_dhcp.limit='100' || return 1
    uci set dhcp.rt_iptv_dhcp.leasetime='12h' || return 1
    uci set dhcp.rt_iptv_dhcp.force='1' || return 1
}

configure_firewall() {
    mode="$1"
    if [ "$mode" = "classic" ]; then
        wan_proto="$(detect_wan_proto)"
        case "$wan_proto" in
            pppoe)
                die "Classic не подходит для PPPoE shared-WAN. Используйте shared-wan после явного указания физического parent."
                ;;
        esac
    elif [ "$mode" = "shared-wan" ] || [ "$mode" = "dsa" ]; then
        upstream_zone='wan'
    elif [ "$mode" = "vlan" ]; then
        uci set firewall.rt_iptv_upstream='zone' || return 1
        uci set firewall.rt_iptv_upstream.name='rt_iptv_upstream' || return 1
        uci add_list firewall.rt_iptv_upstream.network='rt_iptv' || return 1
        uci set firewall.rt_iptv_upstream.input='REJECT' || return 1
        uci set firewall.rt_iptv_upstream.output='ACCEPT' || return 1
        uci set firewall.rt_iptv_upstream.forward='REJECT' || return 1
        uci set firewall.rt_iptv_upstream.masq='0' || return 1
        upstream_zone='rt_iptv_upstream'
    else
        upstream_zone='wan'
    fi

    uci set firewall.rt_iptv_downstream='zone' || return 1
    uci set firewall.rt_iptv_downstream.name='rt_iptv_lan' || return 1
    uci add_list firewall.rt_iptv_downstream.network='rt_iptv_lan' || return 1
    uci set firewall.rt_iptv_downstream.input='REJECT' || return 1
    uci set firewall.rt_iptv_downstream.output='ACCEPT' || return 1
    uci set firewall.rt_iptv_downstream.forward='REJECT' || return 1

    uci set firewall.rt_iptv_igmp_upstream='rule' || return 1
    uci set firewall.rt_iptv_igmp_upstream.name='Rostelecom IPTV IGMP upstream' || return 1
    uci set firewall.rt_iptv_igmp_upstream.src="$upstream_zone" || return 1
    uci set firewall.rt_iptv_igmp_upstream.proto='igmp' || return 1
    uci set firewall.rt_iptv_igmp_upstream.family='ipv4' || return 1
    uci set firewall.rt_iptv_igmp_upstream.target='ACCEPT' || return 1

    uci set firewall.rt_iptv_igmp_downstream='rule' || return 1
    uci set firewall.rt_iptv_igmp_downstream.name='Rostelecom IPTV IGMP downstream' || return 1
    uci set firewall.rt_iptv_igmp_downstream.src='rt_iptv_lan' || return 1
    uci set firewall.rt_iptv_igmp_downstream.proto='igmp' || return 1
    uci set firewall.rt_iptv_igmp_downstream.family='ipv4' || return 1
    uci set firewall.rt_iptv_igmp_downstream.target='ACCEPT' || return 1

    uci set firewall.rt_iptv_dhcp='rule' || return 1
    uci set firewall.rt_iptv_dhcp.name='Rostelecom IPTV DHCP' || return 1
    uci set firewall.rt_iptv_dhcp.src='rt_iptv_lan' || return 1
    uci set firewall.rt_iptv_dhcp.proto='udp' || return 1
    uci set firewall.rt_iptv_dhcp.src_port='68' || return 1
    uci set firewall.rt_iptv_dhcp.dest_port='67' || return 1
    uci set firewall.rt_iptv_dhcp.family='ipv4' || return 1
    uci set firewall.rt_iptv_dhcp.target='ACCEPT' || return 1

    uci set firewall.rt_iptv_dns='rule' || return 1
    uci set firewall.rt_iptv_dns.name='Rostelecom IPTV DNS' || return 1
    uci set firewall.rt_iptv_dns.src='rt_iptv_lan' || return 1
    uci set firewall.rt_iptv_dns.proto='tcp udp' || return 1
    uci set firewall.rt_iptv_dns.dest_port='53' || return 1
    uci set firewall.rt_iptv_dns.family='ipv4' || return 1
    uci set firewall.rt_iptv_dns.target='ACCEPT' || return 1

    uci set firewall.rt_iptv_multicast='rule' || return 1
    uci set firewall.rt_iptv_multicast.name='Rostelecom IPTV multicast' || return 1
    uci set firewall.rt_iptv_multicast.src="$upstream_zone" || return 1
    uci set firewall.rt_iptv_multicast.dest='rt_iptv_lan' || return 1
    uci set firewall.rt_iptv_multicast.proto='udp' || return 1
    uci set firewall.rt_iptv_multicast.dest_ip='224.0.0.0/4' || return 1
    uci set firewall.rt_iptv_multicast.family='ipv4' || return 1
    uci set firewall.rt_iptv_multicast.target='ACCEPT' || return 1
}

altnet_string() {
    value="$DEFAULT_ALTNETS"
    if [ -f "$STATE_DIR/altnets" ]; then
        value="$(cat "$STATE_DIR/altnets")"
    fi
    printf '%s' "$value"
}

configure_igmpproxy() {
    mode="$1"
    altnets="$(altnet_string)"
    upstream_network='wan'
    if [ "$mode" = "vlan" ]; then
        upstream_network='rt_iptv'
    elif [ "$mode" = "shared-wan" ]; then
        upstream_network='rt_iptv_upstream'
    elif [ "$mode" = "dsa" ]; then
        upstream_network='wan'
    fi

    uci set igmpproxy.rt_iptv_upstream='phyint' || return 1
    uci set igmpproxy.rt_iptv_upstream.network="$upstream_network" || return 1
    uci set igmpproxy.rt_iptv_upstream.direction='upstream' || return 1
    for item in $altnets; do
        uci add_list igmpproxy.rt_iptv_upstream.altnet="$item" || return 1
    done

    uci set igmpproxy.rt_iptv_downstream='phyint' || return 1
    uci set igmpproxy.rt_iptv_downstream.network='rt_iptv_lan' || return 1
    uci set igmpproxy.rt_iptv_downstream.direction='downstream' || return 1

    # Keep quickleave explicit; do not force IGMP version globally.
    uci set igmpproxy.rt_iptv='igmpproxy' || return 1
    uci set igmpproxy.rt_iptv.quickleave='1' || return 1
}

configure_igmp_version() {
    version="${IGMP_VERSION:-}"
    [ -n "$version" ] || return 0
    validate_igmp_version "$version" || return 1
    uci set network.rt_iptv_dev.igmpversion="$version"
}

# -----------------------------
# Hotplug
# -----------------------------

install_hotplug() {
    mkdir -p "$(dirname "$HOTPLUG_FILE")" || return 1
    if [ -f "$HOTPLUG_FILE" ] && [ ! -f "$HOTPLUG_BACKUP" ]; then
        cp -p "$HOTPLUG_FILE" "$HOTPLUG_BACKUP" || return 1
    fi
    tmp="$HOTPLUG_FILE.tmp.$$"
    cat > "$tmp" <<'EOF2' || return 1
#!/bin/sh

[ "$ACTION" = "ifup" ] || exit 0

case "$INTERFACE" in
    wan|rt_iptv)
        /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true
        ;;
esac
EOF2
    chmod 0755 "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$HOTPLUG_FILE" || { rm -f "$tmp"; return 1; }
    return 0
}

restore_hotplug() {
    if [ -f "$HOTPLUG_BACKUP" ]; then
        tmp="$HOTPLUG_FILE.restore.$$"
        cp -p "$HOTPLUG_BACKUP" "$tmp" || return 1
        chmod 0755 "$tmp" || { rm -f "$tmp"; return 1; }
        mv "$tmp" "$HOTPLUG_FILE" || { rm -f "$tmp"; return 1; }
        return 0
    fi
    rm -f "$HOTPLUG_FILE" || return 1
    return 0
}

# -----------------------------
# Transaction / apply / rollback
# -----------------------------

service_reload() {
    /etc/init.d/network reload >/dev/null 2>&1 || return 1
    /etc/init.d/firewall reload >/dev/null 2>&1 || return 1
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1
    /etc/init.d/igmpproxy enable >/dev/null 2>&1 || return 1
    /etc/init.d/igmpproxy restart >/dev/null 2>&1 || return 1
    return 0
}

rollback_transaction() {
    TX_ACTIVE=0
    log "Выполняю безопасный rollback проектных изменений..."
    remove_project_uci
    if [ -n "$TX_PORT" ]; then restore_port_membership "$TX_PORT" || warn "Не удалось полностью вернуть исходное членство порта."; fi
    uci commit network >/dev/null 2>&1 || warn "Не удалось зафиксировать rollback network."
    uci commit firewall >/dev/null 2>&1 || warn "Не удалось зафиксировать rollback firewall."
    uci commit dhcp >/dev/null 2>&1 || warn "Не удалось зафиксировать rollback dhcp."
    uci commit igmpproxy >/dev/null 2>&1 || warn "Не удалось зафиксировать rollback igmpproxy."
    /etc/init.d/network reload >/dev/null 2>&1 || warn "Network reload после rollback не удался."
    /etc/init.d/firewall reload >/dev/null 2>&1 || warn "Firewall reload после rollback не удался."
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || warn "Dnsmasq restart после rollback не удался."
    if [ -r "$SERVICE_STATE_DIR/enabled" ]; then restore_service_state || warn "Не удалось восстановить исходное состояние igmpproxy."; fi
    if restore_hotplug >/dev/null 2>&1; then rm -f "$HOTPLUG_BACKUP"; else warn "Не удалось восстановить исходный hotplug; backup сохранён."; fi
    rm -f "$CONFIG_FILE" "$PORTMAP_FILE"
    log "Rollback завершён."
    return 0
}

commit_project() {
    uci commit network || return 1
    uci commit firewall || return 1
    uci commit dhcp || return 1
    uci commit igmpproxy || return 1
    return 0
}

postcheck() {
    errors=0
    uci_has network.rt_iptv_dev || { warn "Отсутствует network.rt_iptv_dev"; errors=$((errors + 1)); }
    uci_has network.rt_iptv_lan || { warn "Отсутствует network.rt_iptv_lan"; errors=$((errors + 1)); }
    [ "$(uci_get network.rt_iptv_lan.device)" = "br-rt-iptv" ] || { warn "rt_iptv_lan не привязан к br-rt-iptv"; errors=$((errors + 1)); }
    [ -d /sys/class/net/br-rt-iptv ] || { warn "br-rt-iptv не создан в runtime"; errors=$((errors + 1)); }
    mode_state="$(state_get mode 2>/dev/null || true)"
    if [ "$mode_state" = "vlan" ] || [ "$mode_state" = "dsa" ] || { [ -n "${TX_PORT:-}" ] && uci_has network.rt_iptv_vlan; }; then
        if [ "$mode_state" = "dsa" ]; then
            vlan_dev="$(uci_get network.rt_iptv_lan.device)"
        else
            vlan_dev="$(uci_get network.rt_iptv_vlan.name)"
        fi
        [ -n "$vlan_dev" ] && [ -d "/sys/class/net/$vlan_dev" ] || { warn "VLAN interface не создан в runtime: ${vlan_dev:-неизвестно}"; errors=$((errors + 1)); }
    fi
    uci_has dhcp.rt_iptv_dhcp || { warn "Отсутствует DHCP section"; errors=$((errors + 1)); }
    uci_has firewall.rt_iptv_downstream || { warn "Отсутствует IPTV firewall zone"; errors=$((errors + 1)); }
    uci_has firewall.rt_iptv_igmp_upstream || { warn "Отсутствует upstream IGMP rule"; errors=$((errors + 1)); }
    uci_has firewall.rt_iptv_igmp_downstream || { warn "Отсутствует downstream IGMP rule"; errors=$((errors + 1)); }
    uci_has firewall.rt_iptv_multicast || { warn "Отсутствует multicast rule"; errors=$((errors + 1)); }
    uci_has igmpproxy.rt_iptv_upstream || { warn "Отсутствует igmpproxy upstream"; errors=$((errors + 1)); }
    uci_has igmpproxy.rt_iptv_downstream || { warn "Отсутствует igmpproxy downstream"; errors=$((errors + 1)); }
    command -v igmpproxy >/dev/null 2>&1 || { warn "Команда igmpproxy не найдена"; errors=$((errors + 1)); }
    if ! service_running; then warn "igmpproxy не работает после применения"; errors=$((errors + 1)); fi
    [ -n "$(uci_get network.rt_iptv_dev.ports)" ] || { warn "br-rt-iptv не имеет IPTV-порта"; errors=$((errors + 1)); }
    [ "$errors" -eq 0 ]
}

# -----------------------------
# Package / install modes
# -----------------------------

ensure_igmpproxy() {
    command -v igmpproxy >/dev/null 2>&1 && return 0
    if command -v apk >/dev/null 2>&1; then
        apk add igmpproxy >/dev/null 2>&1 || {
            apk update >/dev/null 2>&1 || return 1
            apk add igmpproxy >/dev/null 2>&1 || return 1
        }
    elif command -v opkg >/dev/null 2>&1; then
        opkg install igmpproxy >/dev/null 2>&1 || {
            opkg update >/dev/null 2>&1 || return 1
            opkg install igmpproxy >/dev/null 2>&1 || return 1
        }
    else
        return 1
    fi
    command -v igmpproxy >/dev/null 2>&1
}

validate_common_install() {
    mode="$1"
    port="$2"
    parent="$3"
    vid="$4"

    require_clean_uci
    project_installed && die "IPTV уже установлено. Сначала выполните uninstall."
    [ ! -f "$PORTMAP_FILE" ] || die "Найдено старое portmap. Выполните uninstall или удалите остатки после проверки."
    assert_project_names_free

    is_physical_port "$port" || die "IPTV-порт не является физическим Ethernet-портом: $port"
    if port_in_wan_path "$port"; then
        die "Порт $port входит в WAN/management path. Выберите другой физический порт."
    fi

    if [ "$mode" = "vlan" ]; then
        [ -n "$parent" ] || die "Не указан VLAN parent."
        [ -n "$vid" ] || die "Не указан VLAN ID."
        validate_vid "$vid" || die "VLAN ID должен быть 1..4094."
        is_physical_port "$parent" || die "VLAN parent должен быть физическим Ethernet-интерфейсом: $parent"
        [ "$parent" != "$port" ] || die "VLAN parent и IPTV-порт не могут совпадать."
        case "$parent" in *.*|br-*|ppp*|tun*|wg*) die "Legacy VLAN mode принимает только физический parent без точки/bridge/PPP.";; esac
        if port_in_wan_path "$parent"; then
            warn "VLAN parent $parent находится в WAN path. Это допускается только если ваш провайдер действительно использует этот физический parent для отдельного IPTV VLAN."
        fi
        if is_dsa_system; then
            die "Обнаружен DSA. Legacy install-vlan намеренно остановлен: сначала настройте реальную DSA bridge-vlan топологию через UCI/LuCI, затем используйте Classic с готовой network-схемой или отдельный DSA-профиль."
        fi
    fi
}

validate_shared_wan_install() {
    parent="$1"
    port="$2"
    require_clean_uci
    project_installed && die "IPTV уже установлено. Сначала выполните uninstall."
    [ ! -f "$PORTMAP_FILE" ] || die "Найдено старое portmap. Выполните uninstall или удалите остатки после проверки."
    assert_project_names_free
    is_physical_port "$parent" || die "Shared-WAN parent должен быть физическим Ethernet-портом: $parent"
    is_physical_port "$port" || die "IPTV-порт должен быть физическим Ethernet-портом: $port"
    [ "$parent" != "$port" ] || die "Shared-WAN parent и IPTV-порт не могут совпадать."
    if port_in_wan_path "$port"; then
        die "IPTV-порт $port находится в WAN/management path."
    fi
    if [ "$parent" != "$(detect_wan_device)" ] && ! device_contains_port "$(detect_wan_device)" "$parent" 0; then
        die "Parent $parent не находится в обнаруженном WAN path. Откажусь от неоднозначной topology."
    fi
    if is_dsa_system; then
        die "Shared-WAN legacy profile не применяется к DSA. Используйте install-dsa только для уже существующей совместимой DSA bridge topology."
    fi
}

validate_dsa_install() {
    bridge="$1"
    vid="$2"
    port="$3"
    require_clean_uci
    project_installed && die "IPTV уже установлено. Сначала выполните uninstall."
    [ ! -f "$PORTMAP_FILE" ] || die "Найдено старое portmap."
    assert_project_names_free
    is_dsa_system || die "DSA не обнаружен."
    validate_vid "$vid" || die "VLAN ID должен быть 1..4094."
    bridge_sec="$(device_section_by_name "$bridge" 2>/dev/null || true)"
    [ -n "$bridge_sec" ] || die "Bridge $bridge не найден в UCI."
    is_physical_port "$port" || die "IPTV-порт должен быть физическим Ethernet-портом: $port"
    device_ports "$bridge_sec" | tr ' ' '\n' | grep -Fx "$port" >/dev/null 2>&1 || die "Порт $port не является членом bridge $bridge."
    wan="$(detect_wan_device)"
    device_contains_port "$bridge" "$wan" 0 || [ "$wan" = "$bridge" ] || die "WAN не находится в bridge $bridge. DSA профиль остановлен, чтобы не угадывать topology."
    port_in_wan_path "$port" && die "IPTV-порт находится в WAN/management path."
}

install_shared_wan() {
    is_root
    parent="$1"; port="$2"
    igmp_version="${IGMP_VERSION:-}"
    [ -z "$igmp_version" ] || validate_igmp_version "$igmp_version" || die "IGMP_VERSION должен быть 1, 2 или 3."
    validate_shared_wan_install "$parent" "$port"
    save_service_state || die "Не удалось сохранить состояние igmpproxy."
    save_port_membership "$port"
    backup_create before-shared-wan-install
    TX_ACTIVE=1; TX_PORT="$port"
    ensure_igmpproxy || die "Не удалось установить/найти igmpproxy."
    remove_project_uci
    remove_port_from_bridges "$port" || die "Не удалось вывести порт из текущих bridge."
    configure_network_shared_wan "$parent" "$port" || die "Не удалось настроить shared-WAN network."
    configure_igmp_version || die "Не удалось применить IGMP version."
    configure_dhcp || die "Не удалось настроить DHCP."
    configure_firewall shared-wan || die "Не удалось настроить firewall."
    configure_igmpproxy shared-wan || die "Не удалось настроить igmpproxy."
    install_hotplug || die "Не удалось установить hotplug."
    commit_project || die "UCI commit завершился ошибкой."
    service_reload || die "Не удалось применить сетевые сервисы."
    postcheck || die "Post-check установки не пройден."
    write_state shared-wan "$port" "$parent" "" "$(altnet_string)"
    TX_ACTIVE=0
    log "Shared-WAN IPTV установлен. Parent: $parent | Порт приставки: $port"
}

install_dsa() {
    is_root
    bridge="$1"; vid="$2"; port="$3"
    igmp_version="${IGMP_VERSION:-}"
    [ -z "$igmp_version" ] || validate_igmp_version "$igmp_version" || die "IGMP_VERSION должен быть 1, 2 или 3."
    validate_dsa_install "$bridge" "$vid" "$port"
    save_service_state || die "Не удалось сохранить состояние igmpproxy."
    save_port_membership "$port"
    backup_create before-dsa-install
    TX_ACTIVE=1; TX_PORT="$port"
    ensure_igmpproxy || die "Не удалось установить/найти igmpproxy."
    remove_project_uci
    remove_port_from_bridges "$port" || die "Не удалось обновить bridge topology."
    configure_network_dsa "$bridge" "$vid" "$port" || die "Не удалось настроить DSA bridge-vlan."
    configure_igmp_version || die "Не удалось применить IGMP version."
    configure_dhcp || die "Не удалось настроить DHCP."
    configure_firewall dsa || die "Не удалось настроить firewall."
    configure_igmpproxy dsa || die "Не удалось настроить igmpproxy."
    install_hotplug || die "Не удалось установить hotplug."
    commit_project || die "UCI commit завершился ошибкой."
    service_reload || die "Не удалось применить сетевые сервисы."
    postcheck || die "Post-check установки не пройден."
    write_state dsa "$port" "$bridge" "$vid" "$(altnet_string)"
    TX_ACTIVE=0
    log "DSA IPTV установлен. Bridge: $bridge | VLAN: $vid | Порт: $port"
}

install_classic() {
    is_root
    port="$1"
    igmp_version="${IGMP_VERSION:-}"
    [ -z "$igmp_version" ] || validate_igmp_version "$igmp_version" || die "IGMP_VERSION должен быть 1, 2 или 3."
    validate_common_install classic "$port" "" ""

    save_service_state || die "Не удалось сохранить состояние igmpproxy."
    save_port_membership "$port"
    backup_create before-classic-install
    TX_ACTIVE=1
    TX_PORT="$port"

    ensure_igmpproxy || die "Не удалось установить/найти igmpproxy."
    remove_project_uci
    remove_port_from_bridges "$port" || die "Не удалось вывести порт из текущих bridge."
    configure_network_classic "$port" || die "Не удалось настроить network."
    configure_igmp_version || die "Не удалось применить IGMP version."
    configure_dhcp || die "Не удалось настроить DHCP."
    configure_firewall classic || die "Не удалось настроить firewall."
    configure_igmpproxy classic || die "Не удалось настроить igmpproxy."
    install_hotplug || die "Не удалось установить hotplug."

    commit_project || die "UCI commit завершился ошибкой."
    service_reload || die "Не удалось корректно применить сетевые сервисы."
    postcheck || die "Post-check установки не пройден."
    write_state classic "$port" "" "" "$(altnet_string)"
    TX_ACTIVE=0
    log ""
    log "Classic IPTV установлен."
    log "Порт приставки: $port"
}

install_vlan() {
    is_root
    parent="$1"
    vid="$2"
    port="$3"
    igmp_version="${IGMP_VERSION:-}"
    [ -z "$igmp_version" ] || validate_igmp_version "$igmp_version" || die "IGMP_VERSION должен быть 1, 2 или 3."
    validate_common_install vlan "$port" "$parent" "$vid"

    save_service_state || die "Не удалось сохранить состояние igmpproxy."
    save_port_membership "$port"
    backup_create before-vlan-install
    TX_ACTIVE=1
    TX_PORT="$port"

    ensure_igmpproxy || die "Не удалось установить/найти igmpproxy."
    remove_project_uci
    remove_port_from_bridges "$port" || die "Не удалось вывести порт из текущих bridge."
    configure_network_vlan "$parent" "$vid" "$port" || die "Не удалось настроить VLAN network."
    configure_igmp_version || die "Не удалось применить IGMP version."
    configure_dhcp || die "Не удалось настроить DHCP."
    configure_firewall vlan || die "Не удалось настроить firewall."
    configure_igmpproxy vlan || die "Не удалось настроить igmpproxy."
    install_hotplug || die "Не удалось установить hotplug."

    commit_project || die "UCI commit завершился ошибкой."
    service_reload || die "Не удалось корректно применить сетевые сервисы."
    postcheck || die "Post-check установки не пройден."
    write_state vlan "$port" "$parent" "$vid" "$(altnet_string)"
    TX_ACTIVE=0
    log ""
    log "VLAN IPTV установлен."
    log "Parent: $parent | VLAN ID: $vid | Порт приставки: $port"
}

# -----------------------------
# Status / diagnostics / plan
# -----------------------------

status() {
    is_root
    header
    if ! project_installed; then
        log "Статус: IPTV-проект не установлен."
        return 0
    fi
    log "Версия менеджера: $VERSION"
    log "Версия OpenWrt:    $(openwrt_version)"
    log "Режим:             $(state_get mode)"
    log "Порт:              $(state_get port)"
    log "Parent:            $(state_get parent)"
    log "VLAN ID:           $(state_get vid)"
    log "WAN device:        $(detect_wan_device)"
    log "WAN proto:         $(detect_wan_proto)"
    log "DSA:               $(is_dsa_system && printf yes || printf no)"
    log "igmpproxy:         $(command -v igmpproxy 2>/dev/null || printf отсутствует)"
    log ""
    log "UCI project sections:"
    uci show network 2>/dev/null | grep 'rt_iptv' || true
    uci show firewall 2>/dev/null | grep 'rt_iptv' || true
    uci show dhcp 2>/dev/null | grep 'rt_iptv' || true
    uci show igmpproxy 2>/dev/null | grep 'rt_iptv' || true
}

diagnose() {
    is_root
    header
    log "OpenWrt:  $(openwrt_version)"
    log "WAN:      $(detect_wan_device) / $(detect_wan_proto)"
    log "DSA:      $(is_dsa_system && printf yes || printf no)"
    log ""
    log "--- project state ---"
    if project_installed; then
        cat "$CONFIG_FILE"
    else
        log "not installed"
    fi
    log ""
    log "--- interfaces ---"
    ip -br link 2>/dev/null || true
    log ""
    log "--- addresses ---"
    ip -br addr 2>/dev/null || true
    log ""
    log "--- multicast memberships ---"
    cat /proc/net/igmp 2>/dev/null || true
    log ""
    log "--- igmpproxy process ---"
    ps 2>/dev/null | grep '[i]gmpproxy' || log "igmpproxy process not found"
    log ""
    log "--- fw4 IPTV rules ---"
    if command -v fw4 >/dev/null 2>&1; then
        fw4 print 2>/dev/null | grep -Ei 'rt_iptv|224\.0\.0\.0/4|igmpproxy' || true
    else
        log "fw4 command not found"
    fi
    log ""
    log "--- recent logs ---"
    logread 2>/dev/null | tail -n 120 | grep -Ei 'igmp|igmpproxy|multicast|netifd|rt_iptv' || true
}

plan() {
    is_root
    header
    wan="$(detect_wan_device)"
    log "WAN device: ${wan:-не определён}"
    log "WAN proto:  $(detect_wan_proto)"
    if is_dsa_system; then
        log "DSA: обнаружен"
        warn "Автоматическая legacy VLAN настройка отключена для DSA."
    else
        log "DSA: не обнаружен"
    fi
    log ""
    log "Физические порты:"
    ports="$(list_physical_ports)"
    if [ -n "$ports" ]; then
        printf '%s\n' "$ports" | while IFS= read -r port; do
            if port_in_wan_path "$port"; then
                printf '  %-12s BLOCKED WAN/management path\n' "$port"
            else
                printf '  %-12s AVAILABLE\n' "$port"
            fi
        done
    fi
    log ""
    log "Classic: upstream = existing network.wan; no WAN L3 duplication."
    log "VLAN:    legacy 802.1q only; parent + VLAN ID must be explicit."
    log "Safety:  WAN-path ports are blocked for IPTV LAN selection."
    log ""
    log "Default altnets: $(altnet_string)"
}

show_config() {
    is_root
    header
    for cfg in network firewall dhcp igmpproxy; do
        log "--- /etc/config/$cfg ---"
        uci show "$cfg" 2>/dev/null | grep 'rt_iptv' || true
    done
}

# -----------------------------
# altnet management
# -----------------------------

save_altnets() {
    value="$1"
    tmp="$STATE_DIR/altnets.tmp.$$"
    printf '%s\n' "$value" > "$tmp" || return 1
    mv "$tmp" "$STATE_DIR/altnets" || return 1
}

sync_altnets_runtime() {
    project_installed || return 0
    current="$1"
    old="$(uci_list_values igmpproxy.rt_iptv_upstream altnet || true)"
    uci -q delete igmpproxy.rt_iptv_upstream.altnet || true
    for item in $current; do uci add_list igmpproxy.rt_iptv_upstream.altnet="$item" || return 1; done
    uci commit igmpproxy || return 1
    /etc/init.d/igmpproxy restart >/dev/null 2>&1 || {
        uci -q delete igmpproxy.rt_iptv_upstream.altnet || true
        for item in $old; do uci add_list igmpproxy.rt_iptv_upstream.altnet="$item" || true; done
        uci commit igmpproxy >/dev/null 2>&1 || true
        /etc/init.d/igmpproxy restart >/dev/null 2>&1 || true
        return 1
    }
}

add_altnet() {
    is_root
    value="$(normalize_altnet "$1")"
    valid_altnet "$value" || die "Неверный IPv4/CIDR: $1"
    current="$(altnet_string)"
    for item in $current; do
        [ "$item" = "$value" ] && { log "Источник уже существует: $value"; return 0; }
    done
    new="${current}${current:+ }$value"
    save_altnets "$new" || die "Не удалось сохранить altnet."
    if ! sync_altnets_runtime "$new"; then
        save_altnets "$current" || true
        die "Не удалось применить altnet к работающему igmpproxy; состояние откатано."
    fi
    log "Добавлен altnet: $value"
}

remove_altnet() {
    is_root
    value="$(normalize_altnet "$1")"
    valid_altnet "$value" || die "Неверный IPv4/CIDR: $1"
    current="$(altnet_string)"
    result=""
    found=0
    for item in $current; do
        if [ "$item" = "$value" ]; then
            found=1
        else
            result="${result}${result:+ }$item"
        fi
    done
    [ "$found" = "1" ] || { log "Источник не найден: $value"; return 0; }
    [ -n "$result" ] || die "Нельзя удалить последний разрешённый multicast source."
    save_altnets "$result" || die "Не удалось сохранить altnet."
    if ! sync_altnets_runtime "$result"; then
        save_altnets "$current" || true
        die "Не удалось применить altnet к работающему igmpproxy; состояние откатано."
    fi
    log "Удалён altnet: $value"
}

# -----------------------------
# Restore / uninstall
# -----------------------------

restore_full_backup() {
    is_root
    require_clean_uci
    dir="$(latest_backup)"
    [ -n "$dir" ] || die "Backup не найден."
    [ -d "$dir" ] || die "Backup directory not found: $dir"
    [ -f "$dir/MANIFEST" ] || die "Backup не содержит MANIFEST: $dir"
    log "ВНИМАНИЕ: restore заменяет сохранённые /etc/config/network, firewall, dhcp, igmpproxy и связанные IPTV state files."
    confirm "Продолжить восстановление из $dir?" || { log "Отменено."; return 0; }
    backup_create pre-restore
    /etc/init.d/igmpproxy stop >/dev/null 2>&1 || true
    for cfg in network firewall dhcp igmpproxy; do
        if [ -f "$dir/$cfg" ]; then cp -p "$dir/$cfg" "/etc/config/$cfg" || die "Не удалось восстановить $cfg";
        elif [ -f "$dir/$cfg.missing" ]; then rm -f "/etc/config/$cfg" || die "Не удалось удалить $cfg"; fi
    done
    for pair in "portmap:$PORTMAP_FILE" "config:$CONFIG_FILE" "altnets:$STATE_DIR/altnets" "service_enabled:$SERVICE_STATE_DIR/enabled" "service_running:$SERVICE_STATE_DIR/running" "original-hotplug:$HOTPLUG_BACKUP"; do
        name="${pair%%:*}"; dst="${pair#*:}"
        if [ -f "$dir/$name" ]; then
            mkdir -p "$(dirname "$dst")" || die "Не удалось создать каталог состояния"
            cp -p "$dir/$name" "$dst" || die "Не удалось восстановить $name"
        elif [ -f "$dir/$name.missing" ]; then
            rm -f "$dst" || die "Не удалось удалить старое состояние $name"
        fi
    done
    if [ -f "$dir/hotplug" ]; then
        mkdir -p "$(dirname "$HOTPLUG_FILE")" || die "Не удалось создать hotplug directory"
        cp -p "$dir/hotplug" "$HOTPLUG_FILE" || die "Не удалось восстановить hotplug"
        chmod 0755 "$HOTPLUG_FILE" || die "Не удалось выставить права hotplug"
    elif [ -f "$dir/hotplug.missing" ]; then
        rm -f "$HOTPLUG_FILE" || die "Не удалось удалить hotplug"
    fi
    /etc/init.d/network reload >/dev/null 2>&1 || die "Network reload failed after restore."
    /etc/init.d/firewall reload >/dev/null 2>&1 || die "Firewall reload failed after restore."
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || die "Dnsmasq restart failed after restore."
    restore_service_state || die "Не удалось восстановить состояние igmpproxy."
    printf '%s\n' "$dir" > "$STATE_DIR/last_backup"
    log "Полное восстановление завершено."
}

uninstall() {
    is_root
    require_clean_uci
    project_installed || { log "Проект не установлен."; return 0; }
    port="$(state_get port)"
    log "Удаление IPTV проекта. Порт: $port"
    confirm "Удалить только конфигурацию проекта и вернуть порт?" || { log "Отменено."; return 0; }
    backup_create pre-uninstall
    remove_project_uci
    restore_port_membership "$port" || die "Не удалось восстановить исходное членство IPTV-порта."
    uci commit network || die "Не удалось сохранить network uninstall."
    uci commit firewall || die "Не удалось сохранить firewall uninstall."
    uci commit dhcp || die "Не удалось сохранить dhcp uninstall."
    uci commit igmpproxy || die "Не удалось сохранить igmpproxy uninstall."
    /etc/init.d/network reload >/dev/null 2>&1 || die "Network reload после uninstall не удался."
    /etc/init.d/firewall reload >/dev/null 2>&1 || die "Firewall reload после uninstall не удался."
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || die "Dnsmasq restart после uninstall не удался."
    restore_service_state || warn "Не удалось восстановить исходное состояние igmpproxy."
    if restore_hotplug; then rm -f "$HOTPLUG_BACKUP"; else die "Не удалось восстановить исходный hotplug."; fi
    rm -f "$CONFIG_FILE" "$PORTMAP_FILE" "$STATE_DIR/altnets" "$SERVICE_STATE_DIR/enabled" "$SERVICE_STATE_DIR/running"
    rmdir "$SERVICE_STATE_DIR" 2>/dev/null || true
    log "Удаление завершено."
}


# -----------------------------
# Interactive wizard / CLI
# -----------------------------

select_port_interactive() {
    list_ports
    printf '\nВведите порт IPTV (например lan4): '
    read -r selected_port
    [ -n "$selected_port" ] || die "Порт не указан."
    is_physical_port "$selected_port" || die "Порт не является физическим Ethernet-портом: $selected_port"
    port_in_wan_path "$selected_port" && die "Порт $selected_port находится в WAN/management path. Выберите другой порт."
    log "Выбран порт: $selected_port"
    log "Link: $(port_link_state "$selected_port")"
    log "Bridge: $(port_bridge_membership "$selected_port")"
    log "Bridge-VLAN: $(port_bridge_vlan_membership "$selected_port")"
    confirm "Вывести $selected_port из текущего bridge и выделить его под IPTV?" || die "Установка отменена."
    printf '%s' "$selected_port"
}

install_wizard() {
    is_root
    project_installed && die "IPTV уже установлено. Сначала выполните uninstall."
    header
    log "Мастер установки IPTV Ростелеком"
    log ""
    log "1) Classic — upstream через существующую network.wan"
    log "2) VLAN — отдельный legacy 802.1q parent + VLAN ID"
    log "3) Shared-WAN — PPPoE + физический WAN/L2 для IPTV"
    log "4) DSA — существующий bridge + bridge-vlan"
    log ""
    printf 'Выберите режим [1/4]: '
    read -r mode
    case "$mode" in
        1)
            port="$(select_port_interactive)"
            install_classic "$port"
            ;;
        2)
            if is_dsa_system; then
                die "Обнаружен DSA. Legacy VLAN wizard остановлен намеренно. Используйте фактическую bridge-vlan схему OpenWrt."
            fi
            list_ports
            printf '\nВведите физический VLAN parent (например eth0): '
            read -r parent
            is_physical_port "$parent" || die "Parent не является физическим интерфейсом: $parent"
            printf 'Введите VLAN ID [1-4094]: '
            read -r vid
            validate_vid "$vid" || die "Неверный VLAN ID."
            printf 'Введите физический IPTV-порт (например lan4): '
            read -r port
            is_physical_port "$port" || die "IPTV-порт не является физическим Ethernet-портом."
            [ "$parent" != "$port" ] || die "Parent и IPTV-порт не могут совпадать."
            port_in_wan_path "$port" && die "IPTV-порт находится в WAN/management path."
            confirm "Установить legacy VLAN IPTV: parent=$parent, VLAN=$vid, port=$port?" || die "Установка отменена."
            install_vlan "$parent" "$vid" "$port"
            ;;
        3)
            list_ports
            printf '\nВведите физический WAN parent: '
            read -r parent
            printf 'Введите физический IPTV-порт: '
            read -r port
            validate_shared_wan_install "$parent" "$port"
            confirm "Установить Shared-WAN IPTV: parent=$parent, port=$port?" || die "Установка отменена."
            install_shared_wan "$parent" "$port"
            ;;
        4)
            list_ports
            printf '\nВведите существующий DSA bridge (например br-lan): '
            read -r bridge
            printf 'Введите IPTV VLAN ID [1-4094]: '
            read -r vid
            printf 'Введите физический IPTV-порт: '
            read -r port
            validate_dsa_install "$bridge" "$vid" "$port"
            confirm "Добавить IPTV VLAN $vid в существующий DSA bridge $bridge для порта $port?" || die "Установка отменена."
            install_dsa "$bridge" "$vid" "$port"
            ;;
        *) die "Неизвестный режим." ;;
    esac
}

usage() {
    cat <<EOF2
OpenWrt IPTV Rostelecom Manager $VERSION

Использование:
  $0                    интерактивное меню
  $0 install             Classic wizard
  $0 install-vlan P V L legacy 802.1q: parent P, VLAN V, IPTV port L
  $0 install-shared-wan P L   PPPoE/shared-WAN: physical parent P, IPTV port L
  $0 install-dsa B V L       DSA: existing bridge B, VLAN V, IPTV port L
  $0 status
  $0 diagnose
  $0 plan
  $0 list-ports
  $0 show-config
  $0 backup
  $0 restore
  $0 uninstall
  $0 add-altnet IP[/CIDR]
  $0 remove-altnet IP[/CIDR]
  $0 version
  $0 help

Переменная:
  IGMP_VERSION=1|2|3    явно задать IGMP version для bridge
EOF2
}

backup_cmd() {
    is_root
    backup_create manual
}

menu() {
    while :; do
        header
        log "1) Установить IPTV (мастер: Classic / Shared-WAN / DSA)"
        log "2) Статус"
        log "3) Диагностика"
        log "4) Порты / WAN topology"
        log "5) Показать настройки"
        log "6) Создать backup"
        log "7) Удалить IPTV"
        log "8) План / безопасная проверка"
        log "9) Полное restore из backup"
        log "0) Выход"
        printf '\nВыбор: '
        read -r choice
        case "$choice" in
            1) install_wizard; pause_ui ;;
            2) status; pause_ui ;;
            3) diagnose; pause_ui ;;
            4) list_ports; pause_ui ;;
            5) show_config; pause_ui ;;
            6) backup_cmd; pause_ui ;;
            7) uninstall; pause_ui ;;
            8) plan; pause_ui ;;
            9) restore_full_backup; pause_ui ;;
            0) return 0 ;;
            *) log "Неизвестный пункт."; pause_ui ;;
        esac
    done
}

main() {
    command="${1:-menu}"
    case "$command" in
        version|-v|--version|help|-h|--help) ;;
        *) is_root; lock_acquire ;;
    esac
    case "$command" in
        install)
            is_root
            port="${2:-}"
            [ -n "$port" ] || { port="$(select_port_interactive)"; }
            install_classic "$port"
            ;;
        install-vlan)
            [ "$#" -eq 4 ] || die "Использование: $0 install-vlan PARENT VLAN_ID IPTV_PORT"
            install_vlan "$2" "$3" "$4"
            ;;
        install-shared-wan)
            [ "$#" -eq 3 ] || die "Использование: $0 install-shared-wan WAN_PARENT IPTV_PORT"
            install_shared_wan "$2" "$3"
            ;;
        install-dsa)
            [ "$#" -eq 4 ] || die "Использование: $0 install-dsa BRIDGE VLAN_ID IPTV_PORT"
            install_dsa "$2" "$3" "$4"
            ;;
        status) status ;;
        diagnose) diagnose ;;
        plan) plan ;;
        list-ports) list_ports ;;
        show-config) show_config ;;
        backup) backup_cmd ;;
        restore) restore_full_backup ;;
        uninstall) uninstall ;;
        add-altnet)
            [ "$#" -eq 2 ] || die "Использование: $0 add-altnet IP[/CIDR]"
            add_altnet "$2"
            ;;
        remove-altnet)
            [ "$#" -eq 2 ] || die "Использование: $0 remove-altnet IP[/CIDR]"
            remove_altnet "$2"
            ;;
        version|-v|--version) printf '%s\n' "$VERSION" ;;
        help|-h|--help) usage ;;
        menu) is_root; menu ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
