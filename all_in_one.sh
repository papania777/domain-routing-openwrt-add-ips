#!/bin/sh
# =============================================================================
# v6.5-final.sh
# Unified Routing + Sing-Box (Fixed Reload Wipe & Init Script)
# =============================================================================

GREEN='\033[32;1m'; RED='\033[31;1m'; YELLOW='\033[33;1m'; NC='\033[0m'
log_i() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_w() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_e() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# =============================================================================
# 1. CLEANUP & PRE-CREATE
# =============================================================================
v6_cleanup() {
    log_i "Phase 1: Cleanup & Pre-create sets..."
    [ -f /etc/sing-box/config.json ] && cp /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)" 2>/dev/null
    crontab -l 2>/dev/null | grep -v -e "add-ip-subnet-routing" -e "getdomains" -e "v6-unified" | crontab - 2>/dev/null || true
    for r in $(uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_|\.set='vpn_domains'" | cut -d= -f1 | cut -d. -f2); do
        uci delete firewall."$r" >/dev/null 2>&1
    done
    uci commit firewall >/dev/null 2>&1
    rm -f /usr/sbin/apply-vpn-mark-rules.sh /etc/init.d/getdomains /etc/init.d/add-ip-subnet-routing
    for s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        nft flush set inet fw4 "$s" 2>/dev/null || true
    done
    rm -rf /tmp/lst/* /tmp/dnsmasq.d/* /tmp/batch.nft
}

# =============================================================================
# 2. VALIDATE
# =============================================================================
v6_validate() {
    log_i "Phase 2: Validate system..."
    command -v curl >/dev/null 2>&1 || { log_e "curl missing"; exit 1; }
    command -v nft  >/dev/null 2>&1 || { log_e "nft missing"; exit 1; }
    grep -q "99 vpn" /etc/iproute2/rt_tables 2>/dev/null || {
        sed -i '/99.*vpn/d' /etc/iproute2/rt_tables 2>/dev/null
        echo '99 vpn' >> /etc/iproute2/rt_tables
    }
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
# 3. SERVICES (Sing-Box & DNS)
# =============================================================================
v6_setup_services() {
    log_i "Phase 3: Services..."
    if ! command -v sing-box >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1
        opkg install sing-box >/dev/null 2>&1 || { log_e "sing-box install failed"; exit 1; }
    fi
    if [ ! -f /etc/sing-box/config.json ]; then
        mkdir -p /etc/sing-box
        cat > /etc/sing-box/config.json << 'SBEOF'
{"log":{"level":"debug"},"inbounds":[{"type":"tun","interface_name":"tun0","domain_strategy":"ipv4_only","address":["172.16.250.1/30"],"auto_route":false,"strict_route":false,"sniff":true}],"outbounds":[{"type":"socks","tag":"proxy","server":"127.0.0.1","server_port":1080}],"route":{"auto_detect_interface":true}}
SBEOF
        log_i "Sing-box config created. EDIT IT MANUALLY!"
    else
        log_i "Sing-box config exists."
    fi
    /etc/init.d/sing-box enable 2>/dev/null
    /etc/init.d/sing-box restart 2>/dev/null

    opkg list-installed | grep -q dnsmasq-full || {
        opkg update >/dev/null 2>&1; cd /tmp && opkg download dnsmasq-full 2>/dev/null
        opkg remove dnsmasq 2>/dev/null && opkg install dnsmasq-full --cache /tmp 2>/dev/null
        [ -f /etc/config/dhcp-opkg ] && mv /etc/config/dhcp-opkg /etc/config/dhcp
    }
    uci get dhcp.@dnsmasq[0].confdir 2>/dev/null | grep -q /tmp/dnsmasq.d || {
        uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'; uci commit dhcp
    }
    mkdir -p /tmp/dnsmasq.d
    DOMAINS_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    if curl -f -s --max-time 120 -o /tmp/dnsmasq.d/domains.lst "$DOMAINS_URL" 2>/dev/null && [ -s /tmp/dnsmasq.d/domains.lst ]; then
        if dnsmasq --conf-file=/tmp/dnsmasq.d/domains.lst --test 2>&1 | grep -q "syntax check OK"; then
            /etc/init.d/dnsmasq restart 2>/dev/null
            log_i "Domain list loaded & dnsmasq restarted."
        else
            log_w "Domain list syntax check failed"
        fi
    else
        log_w "Failed to download domain list"
    fi
}

# =============================================================================
# 4. FIREWALL UCI & HOTPLUG
# =============================================================================
v6_setup_fw_uci() {
    log_i "Phase 4: Firewall UCI setup..."
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/30-vpnroute << 'HEOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "tun0" ] && sleep 10 && ip route add table vpn default dev tun0
HEOF
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
# 5. LOAD IP LISTS
# =============================================================================
v6_load_list() {
    ln="$1"; ls="$2"; lb="${3:-https://antifilter.download}"
    lu="${lb}/list/${ln}.lst"; lt="/tmp/lst/${ls}.lst"
    mkdir -p /tmp/lst
    curl -f -s --max-time 120 -o "$lt" "$lu" 2>/dev/null || { log_w "Download failed: $ln"; return 1; }
    [ -s "$lt" ] || { log_w "Empty: $ln"; return 1; }
    nft flush set inet fw4 "$ls" 2>/dev/null || true
    sed 's/\r//g' "$lt" | grep -oE '[0-9.]+(/[0-9]{1,2})?' | sort -u > /tmp/lst/${ls}.valid 2>/dev/null || true
    [ -s /tmp/lst/${ls}.valid ] || { rm -f "$lt"; return 1; }
    cnt=0; b=""; done=0
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        [ -z "$b" ] && b="$l" || b="${b}, ${l}"
        cnt=$((cnt+1))
        if [ "$cnt" -ge 500 ]; then
            printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/lst/batch.nft
            nft -f /tmp/lst/batch.nft 2>/dev/null && done=$((done+cnt))
            b=""; cnt=0
        fi
    done < /tmp/lst/${ls}.valid
    if [ -n "$b" ]; then
        printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/lst/batch.nft
        nft -f /tmp/lst/batch.nft 2>/dev/null && done=$((done+cnt))
    fi
    rm -f "$lt" /tmp/lst/${ls}.valid /tmp/lst/batch.nft
    log_i "Loaded ~$done into $ls."
}
v6_load_all() {
    log_i "Phase 5: Loading IP lists..."
    v6_load_list "ip" "vpn_ip" "https://antifilter.download" &
    p1=$!; v6_load_list "subnet" "vpn_subnets" "https://antifilter.download" &
    p2=$!; v6_load_list "community" "vpn_community" "https://community.antifilter.download" &
    p3=$!
    wait $p1 $p2 $p3 2>/dev/null
}

# =============================================================================
# 6. APPLY NFT RULES (AFTER FIREWALL RELOAD!)
# =============================================================================
v6_apply_rules() {
    log_i "Phase 7: Applying nft marking rules (post-reload)..."
    # fw4 создает цепочки prerouting/output. Проверяем и добавляем.
    for chain in prerouting output; do
        for set in vpn_domains vpn_ip vpn_subnets vpn_community; do
            # Добавляем только если правила еще нет
            if ! nft list chain inet fw4 "$chain" 2>/dev/null | grep -q "v6_${set}_${chain}"; then
                nft add rule inet fw4 "$chain" ip daddr "@${set}" meta mark set 0x1 comment "v6_${set}_${chain}" 2>/dev/null || \
                    log_w "Failed to add rule: $set in $chain"
            fi
        done
    done
    log_i "Marking rules active."
}

# =============================================================================
# 7. ROUTE & CRON
# =============================================================================
v6_setup_route() {
    log_i "Phase 8: Route setup..."
    if ip link show tun0 >/dev/null 2>&1; then
        ip route del table vpn default 2>/dev/null
        ip route add table vpn default dev tun0 2>/dev/null && log_i "Route added: default dev tun0 table vpn"
    else
        log_w "tun0 not up yet. Hotplug will add route when interface comes up."
    fi
}

v6_cron() {
    log_i "Phase 9: Cron setup..."
    cmd="0 */12 * * * /etc/init.d/v6-unified-routing start"
    cur=$(crontab -l 2>/dev/null) || cur=""
    echo "$cur" | grep -q "v6-unified-routing" 2>/dev/null && return 0
    { echo "$cur"; echo "$cmd"; } | crontab - 2>/dev/null || log_w "Failed to update crontab"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
}

# =============================================================================
# DIAGNOSTICS
# =============================================================================
v6_diagnose() {
    echo "=== NFT SETS (IP COUNT) ==="
    for s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        cnt=$(nft list set inet fw4 "$s" 2>/dev/null | grep -E "^\s+[0-9]" | wc -l)
        printf "%-20s %s IPs\n" "$s:" "$cnt"
    done
    echo -e "\n=== MARKING RULES ==="
    cnt=$(nft list ruleset 2>/dev/null | grep -c "v6_")
    echo "Found: $cnt rules"
    echo -e "\n=== IP RULE ==="
    ip rule 2>/dev/null | grep "0x1" || echo "Not found"
    echo -e "\n=== VPN ROUTE ==="
    ip route show table vpn 2>/dev/null || echo "Empty"
    echo -e "\n=== SING-BOX ==="
    /etc/init.d/sing-box status 2>&1 | head -2
    echo -e "\n=== DOMAINS ==="
    [ -s /tmp/dnsmasq.d/domains.lst ] && echo "Loaded: $(wc -l < /tmp/dnsmasq.d/domains.lst)" || echo "Not loaded"
}

# =============================================================================
# MAIN
# =============================================================================
v6_main() {
    echo "============================================================"
    echo "  Unified Routing v6.5-Final (Fixed Reload Wipe)"
    echo "============================================================"
    v6_cleanup
    v6_validate
    v6_setup_services
    v6_setup_fw_uci
    
    # КРИТИЧЕСКИ ВАЖНО: reload делаем ДО добавления nft-правил
    log_i "Reloading firewall to build chains..."
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    sleep 2
    
    v6_load_all
    v6_apply_rules
    v6_setup_route
    v6_cron
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    
    v6_diagnose
    echo "============================================================"
    log_i "DONE. Rules preserved. To install for auto-start:"
    log_i "  wget -q -O /etc/init.d/v6-unified-routing <YOUR_SCRIPT_URL>"
    log_i "  chmod +x /etc/init.d/v6-unified-routing"
    echo "============================================================"
}

cmd="${1:-start}"
case "$cmd" in
    start) v6_main ;;
    clean) v6_cleanup; log_i "Cleanup done." ;;
    stop) for s in vpn_domains vpn_ip vpn_subnets vpn_community; do nft flush set inet fw4 "$s" 2>/dev/null || true; done ;;
    reload|restart) "$0" stop; sleep 1; "$0" start ;;
    diagnose) v6_diagnose ;;
    *) echo "Usage: $0 {start|clean|stop|reload|restart|diagnose}"; exit 1 ;;
esac
exit 0