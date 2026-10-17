#!/bin/sh
# OptiRoute - OpenWrt gaming router one-shot installer
#
# Turns a fresh OpenWrt 25.12+ x86-64 install into a low-latency gaming router:
#   - qosmate bufferbloat shaping + gaming priority rules
#   - geomate (Call of Duty geo-filter preset, monitor mode)
#   - AdGuard Home ad blocking (dnsmasq moved to port 54)
#   - UPnP for Open NAT, limited to your gaming devices
#   - CPU / NIC low-latency tuning
#   - final LAN/WAN layout (applied on reboot)
#
# Usage:  cp config.env.example config.env  &&  vi config.env  &&  sh install.sh
#         sh install.sh /path/to/other.env

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG="${1:-$SCRIPT_DIR/config.env}"
LOG=/root/gaming-router-install.log

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
info() { printf '\033[1;34m==>\033[0m %s\n' "$*" | tee -a "$LOG"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*" | tee -a "$LOG"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*" | tee -a "$LOG"; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" | tee -a "$LOG"; exit 1; }

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_ip()  { echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

# Latest GitHub release tag for owner/repo (same method the upstream installers use)
latest_tag() {
    uclient-fetch -q -O - "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | grep -o '"tag_name":"[^"]*' | sed 's/"tag_name":"//'
}

fetch() { # fetch URL DEST
    uclient-fetch -q -O "$2" "$1" || die "Download failed: $1"
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
preflight() {
    : > "$LOG"
    info "Preflight checks"

    [ "$(id -u)" = "0" ] || die "Run as root."
    [ -f /etc/openwrt_release ] || die "This does not look like OpenWrt."
    . /etc/openwrt_release
    command -v apk >/dev/null 2>&1 || die "apk not found. OpenWrt 25.12 or newer is required."
    case "${DISTRIB_TARGET:-}" in
        x86/64) ok "OpenWrt $DISTRIB_RELEASE on x86/64" ;;
        *) warn "Target is '${DISTRIB_TARGET:-unknown}', not x86/64. This installer is only tested on x86/64." ;;
    esac

    [ -f "$CONFIG" ] || die "Config not found: $CONFIG  (copy config.env.example to config.env first)"
    # shellcheck disable=SC1090
    . "$CONFIG"

    for v in WAN_IF LAN_IF LAN_IP LAN_NETMASK DOWN_KBPS UP_KBPS; do
        eval "val=\${$v:-}"
        [ -n "$val" ] || die "$v is empty in $CONFIG"
    done
    [ "$WAN_IF" != "$LAN_IF" ] || die "WAN_IF and LAN_IF must be different ports."
    [ -d "/sys/class/net/$WAN_IF" ] || die "WAN port '$WAN_IF' not found. Ports present: $(ls /sys/class/net | tr '\n' ' ')"
    [ -d "/sys/class/net/$LAN_IF" ] || die "LAN port '$LAN_IF' not found. If it is a USB adapter, install its driver first (see README). Ports present: $(ls /sys/class/net | tr '\n' ' ')"
    is_ip "$LAN_IP" || die "LAN_IP '$LAN_IP' is not a valid IPv4 address."
    is_num "$DOWN_KBPS" && is_num "$UP_KBPS" || die "DOWN_KBPS / UP_KBPS must be whole numbers in kbps."
    [ "$DOWN_KBPS" -ge 1000 ] && [ "$UP_KBPS" -ge 1000 ] || die "DOWN_KBPS / UP_KBPS look too small. They are in kbps (e.g. 370000 = 370 Mbps)."
    for ip in ${GAMING_IPS:-}; do is_ip "$ip" || die "GAMING_IPS entry '$ip' is not a valid IP."; done

    # defaults for anything left out
    : "${WAN_PROTO:=dhcp}" "${APPLY_NETWORK:=1}" "${LINK_PRESET:=ethernet}" "${ROOT_QDISC:=hfsc}"
    : "${ENABLE_QOSMATE:=1}" "${ENABLE_GEOMATE:=1}" "${ENABLE_ADGUARD:=1}" "${ENABLE_UPNP:=1}"
    : "${ENABLE_LOWLATENCY:=1}" "${GEOMATE_COD_PORT:=3074}" "${EXTRA_PACKAGES:=}" "${ASSUME_YES:=0}"
    : "${GAMING_IPS:=}" "${GAMING_MACS:=}" "${PPPOE_USERNAME:=}" "${PPPOE_PASSWORD:=}"

    if [ "$WAN_PROTO" = "pppoe" ] && [ -z "$PPPOE_USERNAME" ]; then
        die "WAN_PROTO is pppoe but PPPOE_USERNAME is empty."
    fi

    info "Checking internet access"
    uclient-fetch -q -O /dev/null https://downloads.openwrt.org/ 2>/dev/null \
        || die "No internet. The router must be online during install (see README: 'Getting online for setup')."
    ok "Internet reachable"

    free_mb=$(df -m / | awk 'NR==2 {print $4}')
    if [ "${free_mb:-0}" -lt 300 ]; then
        warn "Only ${free_mb} MB free on /. AdGuard Home needs room for its data."
        warn "Expand the root partition FROM A LIVE USB first: tools/flash-and-resize.sh"
        warn "Never resize the root filesystem while the router is running from it."
    fi
}

confirm() {
    cat <<EOF

  This will configure the router as follows:

    WAN port ........ $WAN_IF ($WAN_PROTO)
    LAN port ........ $LAN_IF  ->  $LAN_IP / $LAN_NETMASK
    Shaping ......... down ${DOWN_KBPS} kbps / up ${UP_KBPS} kbps ($ROOT_QDISC, $LINK_PRESET)
    Gaming devices .. ${GAMING_IPS:-none}
    qosmate=$ENABLE_QOSMATE  geomate=$ENABLE_GEOMATE  adguard=$ENABLE_ADGUARD  upnp=$ENABLE_UPNP  lowlatency=$ENABLE_LOWLATENCY
    Rewrite network . $APPLY_NETWORK (takes effect after reboot)

  A config backup is saved to /root before anything changes.

EOF
    if [ "$ASSUME_YES" != "1" ]; then
        printf "Type 'yes' to continue: "
        read -r answer
        [ "$answer" = "yes" ] || die "Aborted."
    fi
}

backup() {
    BACKUP="/root/pre-gaming-router-$(date +%Y%m%d-%H%M%S).tar.gz"
    sysupgrade -b "$BACKUP" >/dev/null 2>&1 && ok "Backup saved: $BACKUP" \
        || warn "Could not create a backup with sysupgrade -b (continuing)."
}

keep_on_upgrade() { # add a path to sysupgrade.conf once
    grep -qxF "$1" /etc/sysupgrade.conf 2>/dev/null || echo "$1" >> /etc/sysupgrade.conf
}

# ---------------------------------------------------------------------------
# packages (everything that needs the internet happens before DNS changes)
# ---------------------------------------------------------------------------
install_packages() {
    info "Installing packages"
    apk update >>"$LOG" 2>&1 || die "apk update failed (see $LOG)"
    pkgs="irqbalance ethtool $EXTRA_PACKAGES"
    [ "$ENABLE_GEOMATE" = "1" ] && pkgs="$pkgs curl jq lua luci-lua-runtime"
    [ "$ENABLE_ADGUARD" = "1" ] && pkgs="$pkgs adguardhome"
    [ "$ENABLE_UPNP" = "1" ]    && pkgs="$pkgs luci-app-upnp"
    [ "$WAN_PROTO" = "pppoe" ]  && pkgs="$pkgs ppp ppp-mod-pppoe"
    for p in $pkgs; do
        if apk add "$p" >>"$LOG" 2>&1; then ok "$p"; else warn "Could not install $p (see $LOG)"; fi
    done
}

# ---------------------------------------------------------------------------
# qosmate (fetched from upstream: https://github.com/hudra0/qosmate)
# ---------------------------------------------------------------------------
install_qosmate() {
    info "Installing qosmate"
    tag=$(latest_tag hudra0/qosmate); [ -n "$tag" ] || die "Could not find qosmate release"
    base="https://raw.githubusercontent.com/hudra0/qosmate/$tag"
    fetch "$base/etc/init.d/qosmate" /etc/init.d/qosmate && chmod +x /etc/init.d/qosmate
    fetch "$base/etc/qosmate.sh" /etc/qosmate.sh && chmod +x /etc/qosmate.sh
    [ -f /etc/config/qosmate ] || fetch "$base/etc/config/qosmate" /etc/config/qosmate

    tag=$(latest_tag hudra0/luci-app-qosmate); [ -n "$tag" ] || die "Could not find luci-app-qosmate release"
    base="https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$tag"
    mkdir -p /www/luci-static/resources/view/qosmate /usr/share/luci/menu.d /usr/share/rpcd/acl.d /usr/libexec/rpcd
    for f in settings hfsc cake advanced rules connections custom_rules ipsets statistics; do
        fetch "$base/htdocs/luci-static/resources/view/$f.js" "/www/luci-static/resources/view/qosmate/$f.js"
    done
    fetch "$base/root/usr/share/luci/menu.d/luci-app-qosmate.json" /usr/share/luci/menu.d/luci-app-qosmate.json
    fetch "$base/root/usr/share/rpcd/acl.d/luci-app-qosmate.json" /usr/share/rpcd/acl.d/luci-app-qosmate.json
    fetch "$base/root/usr/libexec/rpcd/luci.qosmate" /usr/libexec/rpcd/luci.qosmate
    fetch "$base/root/usr/libexec/rpcd/luci.qosmate_stats" /usr/libexec/rpcd/luci.qosmate_stats
    chmod +x /usr/libexec/rpcd/luci.qosmate /usr/libexec/rpcd/luci.qosmate_stats
    mkdir -p /etc/qosmate.d
    keep_on_upgrade /etc/qosmate.d/
    ok "qosmate installed ($tag)"
}

configure_qosmate() {
    info "Configuring qosmate"
    uci set qosmate.global.enabled='1'
    uci set qosmate.settings.WAN="$WAN_IF"
    uci set qosmate.settings.DOWNRATE="$DOWN_KBPS"
    uci set qosmate.settings.UPRATE="$UP_KBPS"
    uci set qosmate.settings.ROOT_QDISC="$ROOT_QDISC"
    uci set qosmate.advanced.WASHDSCPUP='1'
    uci set qosmate.advanced.WASHDSCPDOWN='1'
    uci set qosmate.advanced.COMMON_LINK_PRESETS="$LINK_PRESET"

    # One priority rule per gaming device. Only outbound rules are needed:
    # qosmate stores the mark in conntrack and restores it on the way back in.
    for ip in $GAMING_IPS; do
        name="Gaming_$(echo "$ip" | tr . _)"
        if uci show qosmate 2>/dev/null | grep -q "name='$name'"; then
            ok "rule $name already present"
            continue
        fi
        uci add qosmate rule >/dev/null
        uci set qosmate.@rule[-1].name="$name"
        uci set qosmate.@rule[-1].proto='udp'
        uci set qosmate.@rule[-1].src_ip="$ip"
        uci add_list qosmate.@rule[-1].dest_port='!=80'
        uci add_list qosmate.@rule[-1].dest_port='!=443'
        uci set qosmate.@rule[-1].class='cs5'
        uci set qosmate.@rule[-1].counter='1'
        uci set qosmate.@rule[-1].enabled='1'
        ok "priority rule for $ip"
    done
    uci commit qosmate
    /etc/init.d/qosmate enable
    ok "qosmate configured (starts on reboot)"
}

# ---------------------------------------------------------------------------
# geomate (fetched from upstream: https://github.com/hudra0/geomate)
# ---------------------------------------------------------------------------
install_geomate() {
    info "Installing geomate"
    tag=$(latest_tag hudra0/geomate); [ -n "$tag" ] || die "Could not find geomate release"
    base="https://raw.githubusercontent.com/hudra0/geomate/$tag/files/etc"
    mkdir -p /etc/geomate.d
    for file in $(curl -s "https://api.github.com/repos/hudra0/geomate/contents/files/etc/geomate.d?ref=$tag" | jq -r '.[].name'); do
        fetch "$base/geomate.d/$file" "/etc/geomate.d/$file"
    done
    for f in geomate.sh geomate_trigger.sh geolocate.sh; do fetch "$base/$f" "/etc/$f"; done
    fetch "$base/init.d/geomate" /etc/init.d/geomate
    chmod +x /etc/init.d/geomate /etc/geomate.sh /etc/geomate_trigger.sh /etc/geolocate.sh
    [ -f /etc/config/geomate ] || fetch "$base/config/geomate" /etc/config/geomate

    tag=$(latest_tag hudra0/luci-app-geomate); [ -n "$tag" ] || die "Could not find luci-app-geomate release"
    base="https://raw.githubusercontent.com/hudra0/luci-app-geomate/$tag"
    mkdir -p /www/luci-static/resources/view/geomate /usr/share/luci/menu.d /usr/share/rpcd/acl.d /usr/libexec/rpcd
    for f in view.js geofilters.js map.html; do
        fetch "$base/htdocs/luci-static/resources/view/geomate/$f" "/www/luci-static/resources/view/geomate/$f"
    done
    fetch "$base/root/usr/share/luci/menu.d/luci-app-geomate.json" /usr/share/luci/menu.d/luci-app-geomate.json
    fetch "$base/root/usr/share/rpcd/acl.d/luci-app-geomate.json" /usr/share/rpcd/acl.d/luci-app-geomate.json
    fetch "$base/root/usr/libexec/rpcd/luci.geomate" /usr/libexec/rpcd/luci.geomate
    chmod +x /usr/libexec/rpcd/luci.geomate
    keep_on_upgrade /etc/geomate.d/
    ok "geomate installed ($tag)"
}

configure_geomate() {
    info "Configuring geomate (Call of Duty preset, monitor mode)"
    first_ip=$(echo "$GAMING_IPS" | awk '{print $1}')
    uci set geomate.global.enabled='1'
    uci set geomate.global.operational_mode='monitor'
    uci set geomate.global.geolocation_mode='daily'
    uci set geomate.global.strict_mode='0'
    uci set geomate.settings.interface='br-lan'

    if ! uci show geomate 2>/dev/null | grep -q "name='Call of Duty'"; then
        uci add geomate geo_filter >/dev/null
        uci set geomate.@geo_filter[-1].name='Call of Duty'
        uci set geomate.@geo_filter[-1].enabled='1'
        uci set geomate.@geo_filter[-1].protocol='udp'
        uci set geomate.@geo_filter[-1].ip_list='/etc/geomate.d/cod_servers.txt'
        [ -n "$first_ip" ] && uci set geomate.@geo_filter[-1].src_ip="$first_ip"
        uci set geomate.@geo_filter[-1].src_port="$GEOMATE_COD_PORT"
        # Matchmaking/auth servers that must stay reachable (from geomate docs)
        uci add_list geomate.@geo_filter[-1].allowed_ip='185.34.107.128'
        uci add_list geomate.@geo_filter[-1].allowed_ip='185.34.107.129'
    fi
    uci commit geomate
    /etc/init.d/geomate enable

    # Locate the bundled server list in the background (takes a few minutes).
    (/etc/geolocate.sh >/tmp/geolocate.log 2>&1 &)
    ok "geomate configured. Draw your region in Services > Geomate after reboot."
}

# ---------------------------------------------------------------------------
# UPnP, restricted to gaming devices
# ---------------------------------------------------------------------------
configure_upnp() {
    info "Configuring UPnP (secure mode, gaming devices only)"
    [ -f /etc/config/upnpd ] || { warn "upnpd config missing, skipping UPnP"; return; }
    uci set upnpd.@upnpd[0].enabled='1'
    uci set upnpd.@upnpd[0].secure_mode='1'
    while uci -q delete upnpd.@perm_rule[0]; do :; done
    for ip in $GAMING_IPS; do
        uci add upnpd perm_rule >/dev/null
        uci set upnpd.@perm_rule[-1].action='allow'
        uci set upnpd.@perm_rule[-1].ext_ports='1024-65535'
        uci set upnpd.@perm_rule[-1].int_addr="$ip/32"
        uci set upnpd.@perm_rule[-1].int_ports='1024-65535'
        uci set upnpd.@perm_rule[-1].comment="Gaming $ip"
    done
    uci add upnpd perm_rule >/dev/null
    uci set upnpd.@perm_rule[-1].action='deny'
    uci set upnpd.@perm_rule[-1].ext_ports='0-65535'
    uci set upnpd.@perm_rule[-1].int_addr='0.0.0.0/0'
    uci set upnpd.@perm_rule[-1].int_ports='0-65535'
    uci set upnpd.@perm_rule[-1].comment='Default deny'
    uci commit upnpd
    /etc/init.d/miniupnpd enable 2>/dev/null
    ok "UPnP allowed for: ${GAMING_IPS:-nobody (no GAMING_IPS set)}"
}

# ---------------------------------------------------------------------------
# low-latency tuning
# ---------------------------------------------------------------------------
configure_lowlatency() {
    info "Applying low-latency tuning"
    cat > /etc/lowlatency.sh <<EOF
#!/bin/sh
# Generated by OptiRoute install.sh
# CPU: full speed, only shallow idle states (POLL/C1/C1E) allowed.
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "\$g" 2>/dev/null; done
for s in /sys/devices/system/cpu/cpu*/cpuidle/state[3-9]/disable; do echo 1 > "\$s" 2>/dev/null; done
# NICs: no interrupt coalescing (lowest per-packet delay).
ethtool -C $WAN_IF rx-usecs 0 2>/dev/null
ethtool -C $LAN_IF rx-usecs 0 2>/dev/null
exit 0
EOF
    chmod +x /etc/lowlatency.sh
    grep -q lowlatency /etc/rc.local 2>/dev/null || sed -i '/^exit 0/i sh /etc/lowlatency.sh' /etc/rc.local
    keep_on_upgrade /etc/lowlatency.sh
    sh /etc/lowlatency.sh

    uci set network.globals.packet_steering='1'
    uci commit network
    uci set irqbalance.irqbalance.enabled='1' 2>/dev/null && uci commit irqbalance
    /etc/init.d/irqbalance enable 2>/dev/null

    # Software/hardware flow offloading bypasses qosmate's shaping. Keep it off.
    uci set firewall.@defaults[0].flow_offloading='0'
    uci set firewall.@defaults[0].flow_offloading_hw='0'
    uci commit firewall
    ok "CPU/NIC tuning applied and set to run at boot"
}

# ---------------------------------------------------------------------------
# DHCP reservations for gaming devices
# ---------------------------------------------------------------------------
configure_reservations() {
    [ -n "$GAMING_MACS" ] || return 0
    info "Adding DHCP reservations"
    set -- $GAMING_MACS
    for ip in $GAMING_IPS; do
        mac="${1:-}"; [ -n "$mac" ] || break; shift
        if uci show dhcp | grep -qi "mac='$mac'"; then ok "$mac already reserved"; continue; fi
        uci add dhcp host >/dev/null
        uci set dhcp.@host[-1].name="gaming-$(echo "$ip" | tr . -)"
        uci set dhcp.@host[-1].mac="$mac"
        uci set dhcp.@host[-1].ip="$ip"
        ok "$mac -> $ip"
    done
    uci commit dhcp
}

# ---------------------------------------------------------------------------
# AdGuard Home - done LAST because it moves DNS. Until the setup wizard is
# finished, devices on the LAN have no DNS.
# ---------------------------------------------------------------------------
configure_adguard() {
    info "Configuring AdGuard Home"
    [ -f /etc/config/adguardhome ] || { warn "adguardhome not installed, skipping"; return; }
    mkdir -p /opt/adguardhome
    chown adguardhome:adguardhome /opt/adguardhome 2>/dev/null
    uci set adguardhome.config.work_dir='/opt/adguardhome'   # on disk, survives reboots
    uci commit adguardhome
    keep_on_upgrade /opt/adguardhome/

    # dnsmasq keeps DHCP + local names on port 54; AdGuard takes port 53.
    uci set dhcp.@dnsmasq[0].port='54'
    uci -q del_list dhcp.lan.dhcp_option="6,$LAN_IP"
    uci add_list dhcp.lan.dhcp_option="6,$LAN_IP"
    uci commit dhcp
    /etc/init.d/adguardhome enable
    ok "AdGuard Home enabled. FINISH THE WIZARD at http://$LAN_IP:3000 after reboot."
}

# ---------------------------------------------------------------------------
# final network layout (applies on reboot)
# ---------------------------------------------------------------------------
configure_network() {
    info "Writing final LAN/WAN layout"
    uci -q delete network.@device[0].ports
    uci add_list network.@device[0].ports="$LAN_IF"
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$LAN_IP"
    uci set network.lan.netmask="$LAN_NETMASK"

    uci set network.wan=interface
    uci set network.wan.device="$WAN_IF"
    uci set network.wan.proto="$WAN_PROTO"
    if [ "$WAN_PROTO" = "pppoe" ]; then
        uci set network.wan.username="$PPPOE_USERNAME"
        uci set network.wan.password="$PPPOE_PASSWORD"
    fi
    uci set network.wan6=interface
    uci set network.wan6.device="$WAN_IF"
    uci set network.wan6.proto='dhcpv6'
    uci commit network

    uci -q delete dhcp.lan.ignore
    uci commit dhcp
    ok "Network written: LAN $LAN_IF ($LAN_IP), WAN $WAN_IF ($WAN_PROTO)"
}

# ---------------------------------------------------------------------------
main() {
    preflight
    confirm
    backup
    install_packages
    [ "$ENABLE_QOSMATE" = "1" ] && install_qosmate
    [ "$ENABLE_GEOMATE" = "1" ] && install_geomate
    [ "$ENABLE_QOSMATE" = "1" ] && configure_qosmate
    [ "$ENABLE_GEOMATE" = "1" ] && configure_geomate
    [ "$ENABLE_UPNP" = "1" ] && configure_upnp
    [ "$ENABLE_LOWLATENCY" = "1" ] && configure_lowlatency
    configure_reservations
    [ "$ENABLE_ADGUARD" = "1" ] && configure_adguard
    [ "$APPLY_NETWORK" = "1" ] && configure_network
    /etc/init.d/rpcd restart >/dev/null 2>&1
    rm -rf /tmp/luci-* 2>/dev/null

    cat <<EOF

$(printf '\033[1;32m')Install complete.$(printf '\033[0m')  Log: $LOG

Next steps:
  1. Cable it:  $WAN_IF -> modem,  $LAN_IF -> switch / AP / PC
     (power-cycle the modem if it was paired to an old router)
  2. reboot
  3. Browse to http://$LAN_IP  and set a root password if you haven't.
EOF
    [ "$ENABLE_ADGUARD" = "1" ] && cat <<EOF
  4. IMPORTANT: finish AdGuard Home setup at http://$LAN_IP:3000
     Admin UI: All interfaces, port 3000.  DNS: All interfaces, port 53.
     Recommended settings: docs/ADGUARD.md
     Something wrong? Undo with: sh tools/adguard-rollback.sh
EOF
    [ "$ENABLE_GEOMATE" = "1" ] && echo "  5. Draw your game region in Services > Geomate (docs/GEOMATE.md)"
    echo "  6. Run a bufferbloat test and fine-tune (docs/TUNING.md)"
    echo
}

main "$@"
