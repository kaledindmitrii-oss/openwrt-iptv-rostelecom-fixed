# Examples

## Classic

```sh
/tmp/iptv-manager.sh install
```

## Explicit VLAN parent

Only when the provider topology and VLAN ID are known:

```sh
/tmp/iptv-manager.sh install-vlan eth0 100 lan4
```

For DSA bridge VLANs, configure the provider VLAN through OpenWrt's `bridge-vlan` model instead of guessing an `eth0.<VID>` device.
