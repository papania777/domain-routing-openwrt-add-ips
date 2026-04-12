#!/bin/sh
# =============================================================================
# v8.1-default-dns.sh
# Unified Domain + IP/Subnet/Community Routing + Sing-Box
# Перманентный Default DNS, авто-очистка DNSCrypt2/Stubby, ash-совместимость
# =============================================================================

v8_green='\033[32;1m'; v8_red='\033[31;1m'; v8_yellow='\033[33;1m'; v8_nc='\033[0m'
v8_log_i() { printf "${v8_green}[INFO]${v8_nc} %s\n" "$1"; }
v8_log_w() { printf "${v8_yellow}[WARN]${v8_nc} %s\n" "$1"; }
v8_log_e() { printf "${v8_red}[ERROR]${v8_nc} %s\n" "$1"; }

# =============================================================================
# PHASE 1: CLEANUP
# =============================================================================
v8_cleanup() {
    v8_log_i "Phase 1: General cleanup..."
    [ -f /etc/sing-box/config.json ] && cp /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)" 2>/dev/null
    crontab -l 2>/dev/null | grep -v -e "add-ip-subnet-routing" -e "getdomains" -e "v8-unified" | crontab - 2>/dev/null || true
    for v8_r in $(uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_|\.set='vpn_domains'" | cut -d= -f1 | cut -d. -f2); do
        uci delete firewall."$v8_r" >/dev/null 2>&1
    done
    uci commit firewall >/dev/null 2>&1
    rm -f /usr/sbin/v8-mark-rules.sh /etc/init.d/getdomains /etc/init.d/add-ip-subnet-routing
    rm -rf /tmp/lst/* /tmp/dnsmasq.d/* /tmp/v8_batch.nft
    v8_log_i "General cleanup done."
}

# =============================================================================
# PHASE 2: PRE-CREATE NFT SETS
# =============================================================================
v8_create_sets() {
    v8_log_i "Phase 2: Pre-creating nft sets..."
    for v8_s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        nft list set inet fw4 "$v8_s" >/dev/null 2>&1 || \
            nft add set inet fw4 "$v8_s" '{ type ipv4_addr; flags interval; }' 2>/dev/null || \
            v8_log_e "Failed to create set $v8_s"
    done
}

# =============================================================================
# PHASE 3: VALIDATE & REPAIR
# =============================================================================
v8_validate() {
    v8_log_i "Phase 3: Validate system..."
    command -v curl >/dev/null 2>&1 || { v8_log_e "curl missing"; exit 1; }
    command -v nft  >/dev/null 2>&1 || { v8_log_e "nft missing"; exit 1; }
    sed -i '/^[[:space:]]*99[[:space:]]*vpn/d' /etc/iproute2/rt_tables 2>/dev/null || true
    echo '99 vpn' >> /etc/iproute2/rt_tables
    uci show network 2>/dev/null | grep -q "mark='0x1'" || {
        uci add network rule >/dev/null 2>&1
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit network
    }
}

# =============================================================================
# PHASE 3.5: CLEANUP LEGACY DNS RESOLVERS (DNSCrypt2 / Stubby)
# =============================================================================
v8_cleanup_dns() {
    v8_log_i "Phase 3.5: Cleaning up legacy DNS resolvers..."
    v8_dns_cleaned=0

    # DNSCrypt2
    if command -v dnscrypt-proxy >/dev/null 2>&1 || opkg list-installed | grep -q dnscrypt-proxy2; then
        v8_log_i "Stopping & disabling DNSCrypt2..."
        /etc/init.d/dnscrypt-proxy stop 2>/dev/null || true
        /etc/init.d/dnscrypt-proxy disable 2>/dev/null || true
        v8_dns_cleaned=1
    fi

    # Stubby
    if command -v stubby >/dev/null 2>&1 || opkg list-installed | grep -q stubby; then
        v8_log_i "Stopping & disabling Stubby..."
        /etc/init.d/stubby stop 2>/dev/null || true
        /etc/init.d/stubby disable 2>/dev/null || true
        v8_dns_cleaned=1
    fi

    # Restore default dnsmasq behavior (use upstream DNS from /etc/resolv.conf)
    if [ "$v8_dns_cleaned" -eq 1 ] || uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null | grep -q "1"; then
        v8_log_i "Restoring default dnsmasq DNS settings..."
        uci del dhcp.@dnsmasq[0].noresolv 2>/dev/null || true
        uci del dhcp.@dnsmasq[0].server 2>/dev/null || true
        uci commit dhcp 2>/dev/null || true
        /etc/init.d/dnsmasq restart 2>/dev/null || true
    fi
    v8_log_i "DNS resolution set to Default (system upstream)."
}

# =============================================================================
# PHASE 4: DNSMASQ & DOMAIN ROUTING
# =============================================================================
v8_setup_domains() {
    v8_log_i "Phase 4: DNSmasq & Domain Routing..."
    if ! opkg list-installed | grep -q dnsmasq-full; then
        opkg update >/dev/null 2>&1
        cd /tmp && opkg download dnsmasq-full 2>/dev/null
        opkg remove dnsmasq 2>/dev/null && opkg install dnsmasq-full --cache /tmp 2>/dev/null
        [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
        v8_log_i "dnsmasq-full installed."
    fi

    uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d' 2>/dev/null
    uci commit dhcp 2>/dev/null
    mkdir -p /tmp/dnsmasq.d

    v8_dom_url="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    v8_dom_file="/tmp/dnsmasq.d/domains.lst"
    
    if curl -f -s --max-time 120 -o "$v8_dom_file" "$v8_dom_url" 2>/dev/null && [ -s "$v8_dom_file" ]; then
        if dnsmasq --conf-file="$v8_dom_file" --test 2>&1 | grep -q "syntax check OK"; then
            /etc/init.d/dnsmasq stop 2>/dev/null
            /etc/init.d/dnsmasq start 2>/dev/null
            sleep 3
            grep -oE 'nftset=/[^/]+/' "$v8_dom_file" 2>/dev/null | head -3 | sed 's|nftset=/||; s|/||' | while read v8_d; do
                [ -n "$v8_d" ] && nslookup "$v8_d" 127.0.0.1 >/dev/null 2>&1 &
            done
            wait
            v8_log_i "Domain routing configured."
        else
            v8_log_e "Domain list syntax check FAILED."
        fi
    else
        v8_log_w "Failed to download domain list."
    fi
}

# =============================================================================
# PHASE 5: FIREWALL UCI & HOTPLUG
# =============================================================================
v8_setup_fw() {
    v8_log_i "Phase 5: Firewall UCI & Hotplug..."
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/30-vpnroute << 'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "tun0" ] && sleep 10 && ip route add table vpn default dev tun0
EOF
    chmod +x /etc/hotplug.d/iface/30-vpnroute
    cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute 2>/dev/null || true

    uci show firewall | grep -q "@zone.*name='singbox'" || {
        uci add firewall zone
        uci set firewall.@zone[-1].name='singbox'
        uci set firewall.@zone[-1].device='tun0'
        uci set firewall.@zone[-1].forward='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    }
    uci show firewall | grep -q "@forwarding.*name='singbox-lan'" || {
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].name='singbox-lan'
        uci set firewall.@forwarding[-1].dest='singbox'
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    }
}

# =============================================================================
# PHASE 6: SING-BOX SERVICE
# =============================================================================
v8_setup_singbox() {
    v8_log_i "Phase 6: Sing-Box..."
    command -v sing-box >/dev/null 2>&1 || { opkg update >/dev/null 2>&1; opkg install sing-box >/dev/null 2>&1 || exit 1; }
    if [ ! -f /etc/sing-box/config.json ]; then
        mkdir -p /etc/sing-box
        printf '{"log":{"level":"debug"},"inbounds":[{"type":"tun","interface_name":"tun0","domain_strategy":"ipv4_only","address":["172.16.250.1/30"],"auto_route":false,"strict_route":false,"sniff":true}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"auto_detect_interface":true}}\n' > /etc/sing-box/config.json
        v8_log_i "Sing-box config created. EDIT outbounds TO SET YOUR PROXY!"
    fi
    /etc/init.d/sing-box enable 2>/dev/null
    /etc/init.d/sing-box restart 2>/dev/null
}

# =============================================================================
# PHASE 7: LOAD IP LISTS (PARALLEL + BATCH)
# =============================================================================
v8_load_list() {
    v8_ln="$1"; v8_ls="$2"; v8_lb="${3:-https://antifilter.download}"
    v8_lu="${v8_lb}/list/${v8_ln}.lst"; v8_lt="/tmp/lst/${v8_ls}.lst"
    mkdir -p /tmp/lst
    curl -f -s --max-time 120 -o "$v8_lt" "$v8_lu" 2>/dev/null || return 1
    [ -s "$v8_lt" ] || return 1
    nft flush set inet fw4 "$v8_ls" 2>/dev/null || true
    sed 's/\r//g' "$v8_lt" | grep -oE '[0-9.]+(/[0-9]{1,2})?' | sort -u > /tmp/lst/${v8_ls}.valid 2>/dev/null || true
    [ -s /tmp/lst/${v8_ls}.valid ] || return 1
    v8_cnt=0; v8_b=""; v8_done=0
    while IFS= read -r v8_l; do
        [ -z "$v8_l" ] && continue
        [ -z "$v8_b" ] && v8_b="$v8_l" || v8_b="${v8_b}, ${v8_l}"
        v8_cnt=$((v8_cnt+1))
        if [ "$v8_cnt" -ge 500 ]; then
            printf 'add element inet fw4 %s { %s }\n' "$v8_ls" "$v8_b" > /tmp/v8_batch.nft
            nft -f /tmp/v8_batch.nft 2>/dev/null && v8_done=$((v8_done+v8_cnt))
            v8_b=""; v8_cnt=0
        fi
    done < /tmp/lst/${v8_ls}.valid
    if [ -n "$v8_b" ]; then
        printf 'add element inet fw4 %s { %s }\n' "$v8_ls" "$v8_b" > /tmp/v8_batch.nft
        nft -f /tmp/v8_batch.nft 2>/dev/null && v8_done=$((v8_done+v8_cnt))
    fi
    rm -f "$v8_lt" /tmp/lst/${v8_ls}.valid /tmp/v8_batch.nft
    v8_log_i "Loaded ~$v8_done into $v8_ls."
}
v8_load_all() {
    v8_log_i "Phase 7: Loading IP lists..."
    v8_load_list "ip" "vpn_ip" "https://antifilter.download" &
    v8_p1=$!; v8_load_list "subnet" "vpn_subnets" "https://antifilter.download" &
    v8_p2=$!; v8_load_list "community" "vpn_community" "https://community.antifilter.download" &
    v8_p3=$!
    wait $v8_p1 $v8_p2 $v8_p3 2>/dev/null
}

# =============================================================================
# PHASE 8: APPLY RULES & PERSISTENCE
# =============================================================================
v8_apply_rules() {
    v8_log_i "Phase 8: Firewall reload & marking rules..."
    v8_hp="/usr/sbin/v8-mark-rules.sh"
    cat > "$v8_hp" << 'HELPER'
#!/bin/sh
[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0
for v8c in prerouting output; do
    for v8s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        nft list chain inet fw4 "$v8c" 2>/dev/null | grep -q "v8_${v8s}_${v8c}" || \
            nft add rule inet fw4 "$v8c" ip daddr "@$v8s" meta mark set 0x1 comment "v8_${v8s}_${v8c}" 2>/dev/null || true
    done
done
HELPER
    chmod +x "$v8_hp"

    if ! uci show firewall 2>/dev/null | grep -q "v8-mark-rules"; then
        uci add firewall include >/dev/null 2>&1
        uci set firewall.@include[-1].type='script'
        uci set firewall.@include[-1].path="$v8_hp"
        uci set firewall.@include[-1].reload='1'
        uci commit firewall >/dev/null 2>&1
    fi

    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    sleep 2
    "$v8_hp"
    v8_log_i "Marking rules active & persistent."
}

# =============================================================================
# PHASE 9: ROUTE & CRON
# =============================================================================
v8_setup_route() {
    v8_log_i "Phase 9: Route setup..."
    if ip link show tun0 >/dev/null 2>&1; then
        ip route del table vpn default 2>/dev/null
        ip route add table vpn default dev tun0 2>/dev/null && v8_log_i "Route: default dev tun0 table vpn"
    else
        v8_log_w "tun0 not up yet. Hotplug will add route later."
    fi
}
v8_cron() {
    v8_cmd="0 */12 * * * /etc/init.d/v8-unified-routing start"
    v8_cur=$(crontab -l 2>/dev/null) || v8_cur=""
    echo "$v8_cur" | grep -q "v8-unified-routing" 2>/dev/null && return 0
    { echo "$v8_cur"; echo "$v8_cmd"; } | crontab - 2>/dev/null || v8_log_w "Crontab update failed"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
}

# =============================================================================
# DIAGNOSTICS
# =============================================================================
v8_diagnose() {
    echo "=== NFT SETS (IP COUNT) ==="
    for v8_s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        v8_cnt=$(nft list set inet fw4 "$v8_s" 2>/dev/null | grep -cE "^\s+[0-9]" || echo 0)
        printf "%-20s %s IPs\n" "$v8_s:" "$v8_cnt"
    done
    v8_dc=0
    [ -s /tmp/dnsmasq.d/domains.lst ] && v8_dc=$(grep -c "^nftset=" /tmp/dnsmasq.d/domains.lst 2>/dev/null || echo 0)
    printf "\n%-20s %s domains (nftset lines)\n" "Domains list:" "$v8_dc"
    
    echo -e "\n=== MARKING RULES ==="
    v8_rc=$(nft list ruleset 2>/dev/null | grep -c "v8_")
    echo "Found: $v8_rc rules"
    echo -e "\n=== IP RULE ==="
    ip rule 2>/dev/null | grep "0x1" || echo "Not found"
    echo -e "\n=== VPN ROUTE ==="
    ip route show table vpn 2>/dev/null || echo "Empty"
    echo -e "\n=== DNS TEST ==="
    if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then echo "✅ Works"; else echo "❌ Failed"; fi
    echo -e "\n=== SING-BOX ==="
    /etc/init.d/sing-box status 2>&1 | head -2
}

# =============================================================================
# MAIN
# =============================================================================
v8_main() {
    echo "============================================================"
    echo "  Unified Routing v8.1 (Default DNS + Domain/IP Routing)"
    echo "============================================================"
    v8_create_sets
    v8_cleanup
    v8_validate
    v8_cleanup_dns        # <-- НОВАЯ ФАЗА: очистка DNSCrypt/Stubby
    v8_setup_domains
    v8_setup_fw
    v8_setup_singbox
    v8_load_all
    v8_apply_rules
    v8_setup_route
    v8_cron
    v8_diagnose
    echo "============================================================"
    v8_log_i "DONE. DNS set to Default. Domain IPs populate on first query."
    v8_log_i "To save for auto-start, run:"
    v8_log_i "  wget -q -L -O /tmp/v8.sh <SCRIPT_URL> && sed -i 's/\\r\$//' /tmp/v8.sh"
    v8_log_i "  cp /tmp/v8.sh /etc/init.d/v8-unified-routing && chmod +x /etc/init.d/v8-unified-routing"
    echo "============================================================"
}

# =============================================================================
# DISPATCHER
# =============================================================================
v8_cmd="${1:-start}"
case "$v8_cmd" in
    start) v8_main ;;
    clean) v8_cleanup; v8_cleanup_dns; v8_log_i "Cleanup done." ;;
    stop) for v8_s in vpn_domains vpn_ip vpn_subnets vpn_community; do nft flush set inet fw4 "$v8_s" 2>/dev/null || true; done ;;
    reload|restart) "$0" stop; sleep 1; "$0" start ;;
    diagnose) v8_diagnose ;;
    *) echo "Usage: $0 {start|clean|stop|reload|restart|diagnose}"; exit 1 ;;
esac
exit 0