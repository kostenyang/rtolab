#!/bin/sh
# rtolab nested ESXi first-boot configurator (PATCHED 2026-05-27 for ESXi 9.1)
# - vmware-rpctool removed in 9.1; use vmtoolsd instead
# - Reset vmk0 MAC to vmnic0 (OVA shares vmk0 MAC -> ARP collision)
# - Regenerate SSL cert (new hostname)
# - Regenerate SSH host keys (OVA shares them)
if [ -f /etc/rtolab-configured ]; then
    exit 0
fi
GET='/bin/vmtoolsd --cmd'
HOSTNAME=$($GET 'info-get guestinfo.hostname' 2>/dev/null)
IPADDR=$($GET   'info-get guestinfo.ipaddress' 2>/dev/null)
NETMASK=$($GET  'info-get guestinfo.netmask' 2>/dev/null)
GATEWAY=$($GET  'info-get guestinfo.gateway' 2>/dev/null)
VLAN=$($GET     'info-get guestinfo.vlan' 2>/dev/null)
DNS=$($GET      'info-get guestinfo.dns' 2>/dev/null)
DOMAIN=$($GET   'info-get guestinfo.domain' 2>/dev/null)
NTP=$($GET      'info-get guestinfo.ntp' 2>/dev/null)
[ -z "$HOSTNAME" ] && exit 0

# Hostname
esxcli system hostname set --fqdn="$HOSTNAME" 2>/dev/null

# Reset vmk0 to use vmnic0 MAC (drop OVA-baked shared MAC)
VMNIC0_MAC=$(esxcli network nic list | awk '/^vmnic0/ {print $8}')
esxcli network ip interface remove --interface-name=vmk0 2>/dev/null
sleep 1
esxcli network ip interface add --interface-name=vmk0 --portgroup-name="Management Network" --mac-address="$VMNIC0_MAC" 2>/dev/null

# VLAN
[ -n "$VLAN" ] && esxcli network vswitch standard portgroup set -p "Management Network" --vlan-id="$VLAN" 2>/dev/null

# IP (no gateway here; add route separately)
if [ -n "$IPADDR" ] && [ -n "$NETMASK" ]; then
    esxcli network ip interface ipv4 set -i vmk0 -t static -I "$IPADDR" -N "$NETMASK"
fi
# Default gateway via route
[ -n "$GATEWAY" ] && esxcli network ip route ipv4 add --gateway "$GATEWAY" --network default 2>/dev/null
# Re-apply IP with gateway (now route exists)
[ -n "$IPADDR" ] && [ -n "$NETMASK" ] && [ -n "$GATEWAY" ] && esxcli network ip interface ipv4 set -i vmk0 -t static -I "$IPADDR" -N "$NETMASK" -g "$GATEWAY" 2>/dev/null

# DNS
if [ -n "$DNS" ]; then
    esxcli network ip dns server remove --all 2>/dev/null
    esxcli network ip dns server add --server="$DNS"
fi
[ -n "$DOMAIN" ] && esxcli network ip dns search add --domain="$DOMAIN" 2>/dev/null

# NTP
if [ -n "$NTP" ]; then
    /sbin/esxcli system ntp set -s "$NTP" -e true 2>/dev/null
    /etc/init.d/ntpd start 2>/dev/null
fi

# Regenerate SSL cert for new hostname (kills shared OVA cert)
rm -f /etc/vmware/ssl/rui.crt /etc/vmware/ssl/rui.key 2>/dev/null
/sbin/generate-certificates 2>/dev/null

# Regenerate SSH host keys (kills shared OVA keys)
rm -f /etc/ssh/ssh_host_* 2>/dev/null
/etc/init.d/SSH restart 2>/dev/null

# Restart hostd to load new cert
/etc/init.d/hostd restart 2>/dev/null

touch /etc/rtolab-configured
