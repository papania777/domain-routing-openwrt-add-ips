#!/bin/sh
# =============================================================================
# v9.0-final-optimized.sh
# Unified Routing: Domain + IP/Subnet/Community + Sing-Box
# ОПТИМИЗАЦИЯ: Параллельное скачивание + последовательная запись в nft
# ЗАЩИТА: PID-lock, очистка legacy, отсутствие рекурсий, safe RAM usage
# =============================================================================

V9_URL="https://raw.githubusercontent.com/papania777/domain-routing-openwrt-add-ips/refs/heads/main/all_in_one.sh"
V9_LOCK="/tmp/v9-routing.lock"

v9_log() { logger -t "v9-boot" "$1"; printf "[INFO] %s\n" "$1"; }
v9_log_w() { logger -t "v9-boot" "[WARN] $1"; printf "[WARN] %s\n" "$1"; }
v9_log_e() { logger -t "v9-boot" "[ERROR] $1"; printf "[ERROR] %s\n" "$1"; }

# =============================================================================
# 1. PID LOCK & CLEANUP ON EXIT
# =============================================================================
if [ -f "$V9_LOCK" ]; then
    OLD_PID=$(cat "$V9_LOCK" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        v9_log_w "Already running (PID $OLD_PID). Exiting to prevent fork-bomb/OOM."
        exit 0
    fi
    rm -f "$V9_LOCK"
fi
echo $$ > "$V9_LOCK"
trap 'rm -f "$V9_LOCK"; rm -rf /tmp/lst/* /tmp/v9_batch.nft 2>/dev/null' EXIT

# =============================================================================
# 2. SAFE AUTO-INSTALL (No recursion)
# =============================================================================
if [ ! -x /etc/init.d/v9-unified-routing ]; then
    v9_log "Installing to /etc/init.d/v9-unified-routing..."
    if wget -q -O /tmp/v9-install.sh "$V9_URL" 2>/dev/null || curl -fsSL -o /tmp/v9-install.sh "$V9_URL" 2>/dev/null; then
        sed -i 's/\r$//' /tmp/v9-install.sh 2>/dev/null
        if head -n 1 /tmp/v9-install.sh | grep -q '#!/bin/sh'; then
            cp /tmp/v9-install.sh /etc/init.d/v9-unified-routing
            chmod +x /etc/init.d/v9-unified-routing
            /etc/init.d/v9-unified-routing enable 2>/dev/null || true
            rm -f /tmp/v9-install.sh
            v9_log "✅ Installed for auto-start."
        else
            rm -f /tmp/v9-install.sh
        fi
    fi
fi

# =============================================================================
# 3. KILL LEGACY PROCESSES & CLEAN UCI/CRON
# =============================================================================
v9_log "Cleaning legacy processes & configs..."
for proc in getdomains add-ip-subnet-routing v8-unified-routing; do
    pkill -f "$proc" 2>/dev/null || true
done
crontab -l 2>/dev/null | grep -v -e "getdomains" -e "add-ip-subnet-routing" -e "v8-unified" -e "v9-unified" | crontab - 2>/dev/null || true

uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_|\.set='vpn_domains'" | cut -d= -f1 | cut -d. -f2 | while read -r rule; do
    uci delete firewall."$rule" 2>/dev/null
done
uci commit firewall 2>/dev/null || true
rm -f /usr/sbin/v8-mark-rules.sh /usr/sbin/v9-mark-rules.sh /etc/init.d/getdomains /etc/init.d/add-ip-subnet-routing

# =============================================================================
# 4. PRE-CREATE NFT SETS
# =============================================================================
v9_log "Creating nft sets..."
for s in vpn_domains vpn_ip vpn_subnets vpn_community; do
    nft list set inet fw4 "$s" >/dev/null 2>&1 || nft add set inet fw4 "$s" '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
done

# =============================================================================
# 5. VALIDATE & DNS CLEANUP
# =============================================================================
command -v curl >/dev/null 2>&1 || { v9_log_e "curl missing"; exit 1; }
command -v nft  >/dev/null 2>&1 || { v9_log_e "nft missing"; exit 1; }

sed -i '/^[[:space:]]*99[[:space:]]*vpn/d' /etc/iproute2/rt_tables 2>/dev/null || true
echo '99 vpn' >> /etc/iproute2/rt_tables

uci show network 2>/dev/null | grep -q "mark='0x1'" || {
    uci add network rule >/dev/null 2>&1
    uci set network.@rule[-1].name='mark0x1'
    uci set network.@rule[-1].mark='0x1'
    uci set network.@rule[-1].priority='100'
    uci set network.@rule[-1].lookup='vpn'
    uci commit network 2>/dev/null
}

# DNS Cleanup (remove DNSCrypt/Stubby overrides)
command -v dnscrypt-proxy >/dev/null 2>&1 && { /etc/init.d/dnscrypt-proxy stop 2>/dev/null; /etc/init.d/dnscrypt-proxy disable 2>/dev/null; }
command -v stubby >/dev/null 2>&1 && { /etc/init.d/stubby stop 2>/dev/null; /etc/init.d/stubby disable 2>/dev/null; }
uci del dhcp.@dnsmasq[0].noresolv 2>/dev/null
uci del dhcp.@dnsmasq[0].server 2>/dev/null
uci commit dhcp 2>/dev/null

if ! opkg list-installed | grep -q dnsmasq-full; then
    opkg update >/dev/null 2>&1
    cd /tmp && opkg download dnsmasq-full 2>/dev/null
    opkg remove dnsmasq 2>/dev/null && opkg install dnsmasq-full --cache /tmp/ 2>/dev/null
    [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
fi
uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d' 2>/dev/null
uci commit dhcp 2>/dev/null
/etc/init.d/dnsmasq restart 2>/dev/null || true

# =============================================================================
# 6. SING-BOX (Safe start, no restarts during run)
# =============================================================================
v9_log "Checking Sing-Box..."
if ! opkg list-installed | grep -q sing-box; then
    opkg update >/dev/null 2>&1; opkg install sing-box >/dev/null 2>&1
fi
SVC="sing-box"; [ -f "/etc/init.d/podkop" ] && SVC="podkop"

[ -f "/etc/config/$SVC" ] && {
    sed -i "s/option user 'sing-box'/option user 'root'/" "/etc/config/$SVC" 2>/dev/null || true
    uci set "$SVC.@$SVC[0].enabled"='1' 2>/dev/null || true
    uci del "$SVC.@$SVC[0].nofilelimit" 2>/dev/null || true
    uci del "$SVC.@$SVC[0].norlimit" 2>/dev/null || true
    uci commit "$SVC" 2>/dev/null || true
}

[ ! -f /etc/sing-box/config.json ] && {
    mkdir -p /etc/sing-box
    printf '{"log":{"level":"warn"},"inbounds":[{"type":"tun","interface_name":"tun0","domain_strategy":"ipv4_only","address":["172.16.250.1/30"],"auto_route":false,"strict_route":false,"sniff":true}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"auto_detect_interface":true}}\n' > /etc/sing-box/config.json
}

# Start only if not running
if ! ps | grep -v grep | grep -q "sing-box.*run"; then
    /etc/init.d/$SVC stop 2>/dev/null || true
    sleep 1
    /etc/init.d/$SVC start 2>/dev/null || true
fi

# Wait for tun0 (max 15s)
w=0; while [ $w -lt 15 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; w=$((w+1)); done

# =============================================================================
# 7. FIREWALL & HOTPLUG
# =============================================================================
v9_log "Configuring firewall..."
mkdir -p /etc/hotplug.d/iface
printf '%s\n' '#!/bin/sh' '[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "tun0" ] && { sleep 10; ip route add table vpn default dev tun0 2>/dev/null || true; }' > /etc/hotplug.d/iface/30-vpnroute
chmod +x /etc/hotplug.d/iface/30-vpnroute
cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute 2>/dev/null || true

uci show firewall | grep -q "@zone.*name='singbox'" || {
    uci add firewall zone; uci set firewall.@zone[-1].name='singbox'; uci set firewall.@zone[-1].device='tun0'
    uci set firewall.@zone[-1].forward='ACCEPT'; uci set firewall.@zone[-1].output='ACCEPT'; uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].masq='1'; uci set firewall.@zone[-1].mtu_fix='1'; uci set firewall.@zone[-1].family='ipv4'
    uci commit firewall
}
uci show firewall | grep -q "@forwarding.*name='singbox-lan'" || {
    uci add firewall forwarding; uci set firewall.@forwarding[-1].name='singbox-lan'
    uci set firewall.@forwarding[-1].dest='singbox'; uci set firewall.@forwarding[-1].src='lan'; uci set firewall.@forwarding[-1].family='ipv4'
    uci commit firewall
}

# =============================================================================
# 8. LOAD DOMAINS
# =============================================================================
v9_log "Loading domains..."
mkdir -p /tmp/dnsmasq.d
DOM_FILE="/tmp/dnsmasq.d/domains.lst"
curl -f -s --max-time 60 -o "$DOM_FILE" "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst" 2>/dev/null || true
if [ -s "$DOM_FILE" ] && dnsmasq --conf-file="$DOM_FILE" --test 2>&1 | grep -q "syntax check OK"; then
    /etc/init.d/dnsmasq restart 2>/dev/null || true
    v9_log "✅ Domains loaded."
fi

# =============================================================================
# 9. ⚡ LOAD IP LISTS (PARALLEL DOWNLOAD + SEQUENTIAL NFT LOAD)
# =============================================================================
v9_log "⚡ Downloading IP lists in parallel (speed optimized)..."
mkdir -p /tmp/lst
# Параллельное скачивание
for pair in "ip:vpn_ip:https://antifilter.download" "subnet:vpn_subnets:https://antifilter.download" "community:vpn_community:https://community.antifilter.download"; do
    ln="${pair%%:*}"; r="${pair#*:}"; ls="${r%%:*}"; lb="${r#*:}"
    lt="/tmp/lst/${ls}.lst"
    curl -f -s --max-time 120 -o "$lt" "${lb}/list/${ln}.lst" 2>/dev/null &
done
wait # Ждём завершения всех загрузок
v9_log "✅ Downloads complete. Loading sequentially into nft (RAM-safe)..."

# Последовательная запись батчами по 500
for pair in "ip:vpn_ip" "subnet:vpn_subnets" "community:vpn_community"; do
    ls="${pair#*:}"
    lt="/tmp/lst/${ls}.lst"
    [ -s "$lt" ] || continue
    
    nft flush set inet fw4 "$ls" 2>/dev/null || true
    sed 's/\r//g' "$lt" | grep -oE '[0-9.]+(/[0-9]{1,2})?' | sort -u > /tmp/lst/${ls}.valid 2>/dev/null || true
    [ -s /tmp/lst/${ls}.valid ] || continue
    
    cnt=0; b=""; done=0
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        [ -z "$b" ] && b="$l" || b="${b}, ${l}"
        cnt=$((cnt+1))
        if [ "$cnt" -ge 500 ]; then
            printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/v9_batch.nft
            nft -f /tmp/v9_batch.nft 2>/dev/null && done=$((done+cnt))
            b=""; cnt=0
            sync # Сброс кэша ядра для освобождения RAM
        fi
    done < /tmp/lst/${ls}.valid
    
    [ -n "$b" ] && printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/v9_batch.nft && nft -f /tmp/v9_batch.nft 2>/dev/null && done=$((done+cnt))
    rm -f "$lt" /tmp/lst/${ls}.valid /tmp/v9_batch.nft
    v9_log "✅ Loaded $done entries into $ls."
done
v9_log "IP lists processing complete."

# =============================================================================
# 10. APPLY MARKING RULES & ROUTE
# =============================================================================
v9_log "Applying marking rules..."
HP="/usr/sbin/v9-mark-rules.sh"
printf '%s\n' '#!/bin/sh' '[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0' 'for c in prerouting output; do' 'for s in vpn_domains vpn_ip vpn_subnets vpn_community; do' 'nft list chain inet fw4 "$c" 2>/dev/null | grep -q "v9_${s}_${c}" || nft add rule inet fw4 "$c" ip daddr "@$s" meta mark set 0x1 comment "v9_${s}_${c}" 2>/dev/null || true' 'done' 'done' > "$HP"
chmod +x "$HP"

uci show firewall 2>/dev/null | grep -q "v9-mark-rules" || {
    uci add firewall include >/dev/null 2>&1
    uci set firewall.@include[-1].type='script'
    uci set firewall.@include[-1].path="$HP"
    uci set firewall.@include[-1].reload='1'
    uci commit firewall >/dev/null 2>&1
}

/etc/init.d/firewall reload >/dev/null 2>&1 || true
sleep 2
"$HP"

if ip link show tun0 >/dev/null 2>&1; then
    ip route del table vpn default 2>/dev/null || true
    ip route add table vpn default dev tun0 2>/dev/null && v9_log "✅ Route added: default dev tun0 table vpn"
fi

# =============================================================================
# 11. CRON
# =============================================================================
v9_log "Configuring cron..."
/etc/init.d/cron enable 2>/dev/null || true
if ! crontab -l 2>/dev/null | grep -q "v9-unified-routing start"; then
    (crontab -l 2>/dev/null || true; echo "0 */12 * * * /etc/init.d/v9-unified-routing start") | crontab - 2>/dev/null
    /etc/init.d/cron restart 2>/dev/null || true
    v9_log "✅ Cron configured (every 12h)."
fi

v9_log "=== DONE. Routing active. Safe for reboot. ==="