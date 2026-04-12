#!/bin/sh
# =============================================================================
# v6.1-fixed-routing.sh
# Unified Domain + IP/Subnet/Community Routing + Sing-Box (FIXED)
# Исправлено: порядок создания сетов, очистка legacy ipset, диагностика
# =============================================================================

GREEN='\033[32;1m'; RED='\033[31;1m'; YELLOW='\033[33;1m'; NC='\033[0m'
log_i() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_w() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_e() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# =============================================================================
# PHASE 0: PRE-CREATE NFT SETS (CRITICAL FIX #1)
# =============================================================================
v6_precreate_sets() {
    log_i "Phase 0: Pre-creating nft sets (before any service starts)..."
    for s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        if ! nft list set inet fw4 "$s" >/dev/null 2>&1; then
            nft add set inet fw4 "$s" '{ type ipv4_addr; flags interval; }' 2>/dev/null || \
                log_e "Failed to create set $s"
        fi
    done
    log_i "All nft sets pre-created."
}

# =============================================================================
# PHASE 1: DEEP CLEANUP
# =============================================================================
v6_cleanup() {
    log_i "Phase 1: Deep cleanup..."
    
    # Бэкап конфига Sing-Box
    [ -f /etc/sing-box/config.json ] && cp /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)"
    
    # Очистка cron
    cr_cur=$(crontab -l 2>/dev/null) || cr_cur=""
    cr_new=$(echo "$cr_cur" | grep -v -e "add-ip-subnet-routing" -e "getdomains" -e "v6-unified")
    [ "$cr_cur" != "$cr_new" ] && echo "$cr_new" | crontab - 2>/dev/null && log_i "Cleared old cron."
    
    # Удаление legacy UCI-правил с ipset (CRITICAL FIX #2)
    for r in $(uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_|\.set='vpn_domains'" | cut -d= -f1 | cut -d. -f2); do
        uci delete firewall."$r" >/dev/null 2>&1
    done
    uci commit firewall >/dev/null 2>&1
    
    # Удаление старых скриптов
    rm -f /usr/sbin/apply-vpn-mark-rules.sh /etc/init.d/getdomains /etc/init.d/add-ip-subnet-routing
    rm -f /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute
    
    # Очистка временных файлов
    rm -rf /tmp/lst/* /tmp/dnsmasq.d/* /tmp/batch.nft
    log_i "Cleanup completed."
}

# =============================================================================
# PHASE 2: SYSTEM REPAIR
# =============================================================================
v6_validate() {
    log_i "Phase 2: System validation..."
    command -v curl >/dev/null 2>&1 || { log_e "curl missing"; exit 1; }
    command -v nft  >/dev/null 2>&1 || { log_e "nft missing"; exit 1; }
    
    # rt_tables
    grep -q "^[[:space:]]*99[[:space:]]*vpn" /etc/iproute2/rt_tables 2>/dev/null || {
        sed -i '/^[[:space:]]*99[[:space:]]*vpn/d' /etc/iproute2/rt_tables 2>/dev/null
        echo '99 vpn' >> /etc/iproute2/rt_tables
    }
    
    # mark0x1 rule
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
# PHASE 3: SING-BOX (Safe, no overwrite)
# =============================================================================
v6_setup_singbox() {
    log_i "Phase 3: Sing-Box setup..."
    if ! command -v sing-box >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 && opkg install sing-box >/dev/null 2>&1 || { log_e "sing-box install failed"; exit 1; }
    fi
    
    # Создаём конфиг ТОЛЬКО если файла нет (FIX #3)
    if [ ! -f /etc/sing-box/config.json ]; then
        mkdir -p /etc/sing-box
        cat > /etc/sing-box/config.json << 'SBEOF'
{
  "log": { "level": "debug" },
  "inbounds": [
    {
      "type": "tun",
      "interface_name": "tun0",
      "domain_strategy": "ipv4_only",
      "address": ["172.16.250.1/30"],
      "auto_route": false,
      "strict_route": false,
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "proxy",
      "server": "127.0.0.1",
      "server_port": 1080
    }
  ],
  "route": { "auto_detect_interface": true }
}
SBEOF
        log_i "Sing-box config created. EDIT /etc/sing-box/config.json TO SET YOUR PROXY!"
    else
        log_i "Sing-box config exists (preserved)."
    fi
    /etc/init.d/sing-box enable 2>/dev/null; /etc/init.d/sing-box restart 2>/dev/null
}

# =============================================================================
# PHASE 4: FIREWALL & HOTPLUG (Direct nft rules only)
# =============================================================================
v6_setup_firewall() {
    log_i "Phase 4: Firewall setup..."
    
    # Hotplug для tun0
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/30-vpnroute << 'HEOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "tun0" ] && sleep 10 && ip route add table vpn default dev tun0
HEOF
    chmod +x /etc/hotplug.d/iface/30-vpnroute
    cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute 2>/dev/null || true
    
    # Зона singbox
    if ! uci show firewall | grep -q "@zone.*name='singbox'"; then
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
    fi
    
    # Forwarding
    if ! uci show firewall | grep -q "@forwarding.*name='singbox-lan'"; then
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].name='singbox-lan'
        uci set firewall.@forwarding[-1].dest='singbox'
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    fi
}

# =============================================================================
# PHASE 5: DNSMASQ + DOMAINS (with verification)
# =============================================================================
v6_setup_dns() {
    log_i "Phase 5: DNS & domain routing..."
    
    # dnsmasq-full
    opkg list-installed | grep -q dnsmasq-full || {
        opkg update >/dev/null 2>&1
        cd /tmp && opkg download dnsmasq-full 2>/dev/null
        opkg remove dnsmasq 2>/dev/null && opkg install dnsmasq-full --cache /tmp 2>/dev/null
        [ -f /etc/config/dhcp-opkg ] && mv /etc/config/dhcp-opkg /etc/config/dhcp
    }
    
    # confdir для 24.10+
    uci get dhcp.@dnsmasq[0].confdir 2>/dev/null | grep -q /tmp/dnsmasq.d || {
        uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
        uci commit dhcp
    }
    
    # Загрузка доменов
    mkdir -p /tmp/dnsmasq.d
    DOMAINS_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    if curl -f -s --max-time 120 -o /tmp/dnsmasq.d/domains.lst "$DOMAINS_URL" 2>/dev/null && [ -s /tmp/dnsmasq.d/domains.lst ]; then
        if dnsmasq --conf-file=/tmp/dnsmasq.d/domains.lst --test 2>&1 | grep -q "syntax check OK"; then
            /etc/init.d/dnsmasq restart 2>/dev/null
            log_i "Domain list loaded and dnsmasq restarted."
        else
            log_w "Domain list syntax check failed"
        fi
    else
        log_w "Failed to download domain list"
    fi
}

# =============================================================================
# PHASE 6: IP/SUBNET/COMMUNITY LOAD
# =============================================================================
v6_load_list() {
    ln="$1"; ls="$2"; lb="${3:-https://antifilter.download}"
    lu="${lb}/list/${ln}.lst"; lt="/tmp/lst/${ls}.lst"
    mkdir -p /tmp/lst
    curl -f -s --max-time 120 -o "$lt" "$lu" 2>/dev/null || { log_w "Download failed: $ln"; return 1; }
    [ -s "$lt" ] || { log_w "Empty: $ln"; return 1; }
    
    # Очистка + загрузка батчами
    nft flush set inet fw4 "$ls" 2>/dev/null || true
    sed 's/\r//g' "$lt" | grep -oE '[0-9.]+(/[0-9]{1,2})?' | sort -u > /tmp/lst/${ls}.valid 2>/dev/null || true
    [ -s /tmp/lst/${ls}.valid ] || { rm -f "$lt"; return 1; }
    
    cnt=0; b=""; done=0
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        [ -z "$b" ] && b="$l" || b="${b}, ${l}"
        cnt=$((cnt+1))
        if [ $cnt -ge 500 ]; then
            printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/lst/batch.nft
            nft -f /tmp/lst/batch.nft 2>/dev/null && done=$((done+cnt))
            b=""; cnt=0
        fi
    done < /tmp/lst/${ls}.valid
    [ -n "$b" ] && printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/lst/batch.nft && nft -f /tmp/lst/batch.nft 2>/dev/null && done=$((done+cnt))
    
    rm -f "$lt" /tmp/lst/${ls}.valid /tmp/lst/batch.nft
    log_i "Loaded ~$done entries into $ls."
}

v6_load_all() {
    log_i "Phase 6: Loading IP lists..."
    v6_load_list "ip" "vpn_ip" "https://antifilter.download" &
    p1=$!; v6_load_list "subnet" "vpn_subnets" "https://antifilter.download" &
    p2=$!; v6_load_list "community" "vpn_community" "https://community.antifilter.download" &
    p3=$!
    wait $p1 $p2 $p3 2>/dev/null
}

# =============================================================================
# PHASE 7: DIRECT NFT MARKING RULES (No UCI ipset)
# =============================================================================
v6_apply_rules() {
    log_i "Phase 7: Applying direct nft marking rules..."
    hp="/usr/sbin/apply-vpn-mark-rules.sh"
    
    printf '%s\n' '#!/bin/sh' \
        '[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0' \
        'for c in prerouting output; do' \
        '    for s in vpn_domains vpn_ip vpn_subnets vpn_community; do' \
        '        nft list chain inet fw4 "$c" 2>/dev/null | grep -q "v6_${s}_${c}" || \' \
        '            nft add rule inet fw4 "$c" ip daddr @"$s" meta mark set 0x1 comment "v6_${s}_${c}" 2>/dev/null || true' \
        '    done' \
        'done' > "$hp"
    chmod +x "$hp"
    
    # Регистрация в UCI для persistence
    uci show firewall 2>/dev/null | grep -q "apply-vpn-mark-rules" || {
        uci add firewall include >/dev/null 2>&1
        uci set firewall.@include[-1].type='script'
        uci set firewall.@include[-1].path="$hp"
        uci set firewall.@include[-1].reload='1'
        uci commit firewall >/dev/null 2>&1
    }
    "$hp"
    log_i "Marking rules active."
}

# =============================================================================
# PHASE 8: CRON & FINAL
# =============================================================================
v6_cron() {
    log_i "Phase 8: Cron setup..."
    cmd="0 */12 * * * /etc/init.d/v6-unified-routing start"
    cur=$(crontab -l 2>/dev/null) || cur=""
    echo "$cur" | grep -q "v6-unified-routing" 2>/dev/null && return 0
    { echo "$cur"; echo "$cmd"; } | crontab - 2>/dev/null || log_w "Crontab failed"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
}

v6_diagnose() {
    log_i "=== DIAGNOSTICS ==="
    echo "1. nft sets:"
    for s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        cnt=$(nft list set inet fw4 "$s" 2>/dev/null | grep -c "elements" 2>/dev/null || echo 0)
        printf "   %-20s %s entries\n" "$s:" "$cnt"
    done
    echo "2. Marking rules:"
    nft list ruleset 2>/dev/null | grep -c "comment.*v6_" || echo "0 rules found"
    echo "3. Sing-box status:"
    /etc/init.d/sing-box status 2>&1 | head -2
    echo "4. dnsmasq domain list:"
    [ -s /tmp/dnsmasq.d/domains.lst ] && echo "   Loaded: $(wc -l < /tmp/dnsmasq.d/domains.lst) lines" || echo "   NOT LOADED"
    echo "5. Test routing (replace 1.1.1.1 with IP from list):"
    echo "   tcpdump -i tun0 -n -c 1 host 1.1.1.1 &"
    echo "   ping -c 1 1.1.1.1"
    log_i "=== END DIAGNOSTICS ==="
}

# =============================================================================
# MAIN
# =============================================================================
v6_main() {
    echo "============================================================"
    echo "  Unified Routing v6.1-Fixed (Self-Healing)"
    echo "============================================================"
    
    v6_precreate_sets    # FIX #1: Sets before anything else
    v6_cleanup
    v6_validate
    v6_setup_singbox
    v6_setup_firewall
    v6_setup_dns         # FIX #2: dnsmasq after sets exist
    v6_load_all
    v6_apply_rules       # FIX #3: Direct nft rules only
    v6_cron
    
    log_i "Reloading firewall..."
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    
    v6_diagnose          # Auto-diagnostics at end
    
    echo "============================================================"
    log_i "DONE. If routing doesn't work, check diagnostics above."
    echo "============================================================"
}

v6_cmd="${1:-start}"
case "$v6_cmd" in
    start) v6_main ;;
    clean) v6_cleanup; log_i "Cleanup done." ;;
    stop) log_i "Clearing..."; for s in vpn_ip vpn_subnets vpn_community vpn_domains; do nft flush set inet fw4 "$s" 2>/dev/null || true; done ;;
    reload|restart) "$0" stop; sleep 1; "$0" start ;;
    diagnose) v6_diagnose ;;
    *) echo "Usage: $0 {start|clean|stop|reload|restart|diagnose}"; exit 1 ;;
esac
exit 0