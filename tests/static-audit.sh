#!/bin/sh
set -eu

file="iptv-manager.sh"

sh -n "$file"

grep -q '^VERSION="5\.5\.0"' "$file"
grep -q 'port_in_wan_path()' "$file"
grep -q 'project_installed && die' "$file"
grep -q 'uci add_list' "$file"
grep -q 'uci del_list' "$file"
grep -q 'DEVTYPE=dsa' "$file"
grep -q 'apk add igmpproxy' "$file"
grep -q 'opkg install igmpproxy' "$file"
grep -q 'IGMP_VERSION' "$file"
grep -q 'rollback_transaction' "$file"
grep -q 'restore_full_backup' "$file"
grep -q 'MANIFEST' "$file"
grep -q 'uci_list_values' "$file"

if grep -nE 'curl|wget|uclient-fetch|https?://' "$file"; then
    echo 'FAIL: remote download logic found in installer' >&2
    exit 1
fi

if grep -nE '(/etc/config/(network|firewall|dhcp|igmpproxy).*)<(.*)|cat .* > /etc/config/(network|firewall|dhcp|igmpproxy)' "$file"; then
    echo 'FAIL: wholesale config replacement pattern found' >&2
    exit 1
fi

if grep -nE 'macaddr|option macaddr|pppoe_(username|password)' "$file"; then
    echo 'FAIL: WAN MAC/PPPoE credentials found in installer' >&2
    exit 1
fi

echo 'STATIC AUDIT PASS'
