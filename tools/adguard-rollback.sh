#!/bin/sh
# Undo the AdGuard Home DNS change: put dnsmasq back on port 53 and stop AdGuard.
# Use this if DNS is broken (e.g. the AdGuard setup wizard was never finished).
#
#   sh tools/adguard-rollback.sh

/etc/init.d/adguardhome stop 2>/dev/null
/etc/init.d/adguardhome disable 2>/dev/null

uci -q delete dhcp.@dnsmasq[0].port
LAN_IP=$(uci -q get network.lan.ipaddr | cut -d/ -f1)
[ -n "$LAN_IP" ] && uci -q del_list dhcp.lan.dhcp_option="6,$LAN_IP"
uci commit dhcp
/etc/init.d/dnsmasq restart

echo "dnsmasq is back on port 53 and AdGuard Home is stopped."
echo "Renew DHCP on your devices (or reconnect) to pick it up."
echo "To try AdGuard again: /etc/init.d/adguardhome enable && /etc/init.d/adguardhome start,"
echo "then set dnsmasq port 54 and finish the wizard at http://$LAN_IP:3000"
