#!/bin/sh
# =============================================================================
# v6.0-unified-singbox.sh
# Unified Domain + IP/Subnet/Community Routing + Sing-Box Installer
# Заменяет getdomains-install.sh + add-ip-subnet-routing
# Источники:
#   - Домены: https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst
#   - IP/Subnet/Community: https://antifilter.download, https://community.antifilter.download
# Совместимость: OpenWrt 23.05/24.10, ash (stream), fw4/nft, 256MB RAM
# =============================================================================

GREEN='\033[32;1m'; RED='\033[31;1m'; YELLOW='\033[33;1m'; NC='\033[0m'
log_i() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_w() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_e() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# =============================================================================
# PHASE 1: DEEP CLEANUP & MIGRATION
# =============================================================================
v6_cleanup() {
    log_i "Phase 1: Deep cleanup & migration..."
    
    # 1. Бэкап конфига Sing-Box (критично!)
    if [ -f /etc/sing-box/config.json ]; then
        cp /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)"
        log_i "Sing-box config backed up."
    fi

    # 2. Очистка cron
    cr_cur=$(crontab -l 2>/dev/null) || cr_cur=""
    cr_new=$(echo "$cr_cur" | grep -v -e "add-ip-subnet-routing" -e "getdomains")
    if [ "$cr_cur" != "$cr_new" ]; then
        echo "$cr_new" | crontab - 2>/dev/null || true
        log_i "Cleared old cron entries."
    fi

    # 3. Удаление старых UCI-правил
    uci_rules=$(uci show firewall 2>/dev/null | grep -E "\.(ipset|set)='vpn_|path.*apply-vpn-mark-rules")
    if [ -n "$uci_rules" ]; then
        for r in $(echo "$uci_rules" | cut -d= -f1 | cut -d. -f2); do
            uci delete firewall."$r" >/dev/null 2>&1 || true
        done
        uci commit firewall >/dev/null 2>&1
        log_i "Cleared legacy UCI firewall rules."
    fi

    # 4. Удаление старых скриптов
    rm -f /usr/sbin/apply-vpn-mark-rules.sh /etc/init.d/add-ip-subnet-routing /etc/init.d/getdomains
    rm -f /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute
    log_i "Removed old scripts & hotplug rules."

    # 5. Очистка nft sets
    for s in vpn_ip vpn_subnets vpn_community vpn_domains; do
        nft flush set inet fw4 "$s" 2>/dev/null || true
    done
    
    # 6. Очистка временных файлов
    rm -rf /tmp/lst/* /tmp/batch.nft /tmp/dnsmasq.d/domains.lst
    log_i "Flushed nft sets & cleared temp files."
}

# =============================================================================
# PHASE 2: SYSTEM VALIDATION & REPAIR
# =============================================================================
v6_validate() {
    log_i "Phase 2: System validation & repair..."
    command -v curl >/dev/null 2>&1 || { log_e "curl missing"; exit 1; }
    command -v nft  >/dev/null 2>&1 || { log_e "nft missing"; exit 1; }
    nft list table inet fw4 >/dev/null 2>&1 || { log_e "Table inet fw4 not found"; exit 1; }

    # Исправление rt_tables
    if grep -q "^[[:space:]]*99[[:space:]]*vpn" /etc/iproute2/rt_tables 2>/dev/null; then
        sed -i '/^[[:space:]]*99[[:space:]]*vpn/d' /etc/iproute2/rt_tables 2>/dev/null || true
    fi
    echo '99 vpn' >> /etc/iproute2/rt_tables
    log_i "Fixed rt_tables (99 vpn)."

    # Проверка/создание правила маркировки
    if ! uci show network 2>/dev/null | grep -q "mark='0x1'"; then
        uci add network rule >/dev/null 2>&1
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit network
        log_i "Created network routing rule (mark0x1)."
    fi
}

# =============================================================================
# PHASE 3: SING-BOX SETUP (Safe, with backup)
# =============================================================================
v6_setup_singbox() {
    log_i "Phase 3: Setting up Sing-Box..."
    
    # Установка
    if ! command -v sing-box >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1
        opkg install sing-box >/dev/null 2>&1 || { log_e "Failed to install sing-box"; exit 1; }
        log_i "Sing-box installed."
    else
        log_i "Sing-box already installed."
    fi

    # Конфигурация (только если файла нет)
    if [ ! -f /etc/sing-box/config.json ]; then
        log_i "Creating default sing-box config..."
        mkdir -p /etc/sing-box
        cat > /etc/sing-box/config.json << 'SBEOF'
{
  "log": { "level": "warn" },
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
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": { "auto_detect_interface": true }
}
SBEOF
        log_i "Config created. Edit /etc/sing-box/config.json manually!"
    else
        log_i "Sing-box config exists (preserved from backup)."
    fi

    # Включение сервиса
    /etc/init.d/sing-box enable 2>/dev/null || true
    /etc/init.d/sing-box restart 2>/dev/null || true
    log_i "Sing-box service restarted."
}

# =============================================================================
# PHASE 4: FIREWALL & NETWORK (Sing-Box only)
# =============================================================================
v6_setup_firewall() {
    log_i "Phase 4: Configuring Firewall & Network..."
    
    # 1. Hotplug для tun0
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/30-vpnroute << 'HEOF'
#!/bin/sh
if [ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "tun0" ]; then
    sleep 10
    ip route add table vpn default dev tun0
fi
HEOF
    chmod +x /etc/hotplug.d/iface/30-vpnroute
    cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute 2>/dev/null || true
    log_i "Hotplug rule for tun0 created."

    # 2. Создание зоны singbox
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
        log_i "Firewall zone 'singbox' created."
    fi

    # 3. Forwarding lan -> singbox
    if ! uci show firewall | grep -q "@forwarding.*name='singbox-lan'"; then
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].name='singbox-lan'
        uci set firewall.@forwarding[-1].dest='singbox'
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
        log_i "Forwarding lan -> singbox created."
    fi

    # 4. Создание nft sets
    for s in vpn_ip vpn_subnets vpn_community; do
        if ! nft list set inet fw4 "$s" >/dev/null 2>&1; then
            nft add set inet fw4 "$s" '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
        fi
    done
    log_i "nft sets prepared."
}

# =============================================================================
# PHASE 5: DNS & DNsmasq (Domain routing)
# =============================================================================
v6_setup_dns() {
    log_i "Phase 5: Configuring DNS & Dnsmasq..."
    
    # Установка dnsmasq-full
    if ! opkg list-installed | grep -q dnsmasq-full; then
        opkg update >/dev/null 2>&1
        cd /tmp/ && opkg download dnsmasq-full 2>/dev/null
        opkg remove dnsmasq 2>/dev/null && opkg install dnsmasq-full --cache /tmp/ 2>/dev/null
        [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
        log_i "dnsmasq-full installed."
    fi

    # Настройка confdir
    if uci get dhcp.@dnsmasq[0].confdir 2>/dev/null | grep -q /tmp/dnsmasq.d; then
        log_i "Dnsmasq confdir already set."
    else
        uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
        uci commit dhcp
        /etc/init.d/dnsmasq restart 2>/dev/null || true
        log_i "Dnsmasq confdir configured."
    fi
}

# =============================================================================
# PHASE 6: DOMAIN LIST DOWNLOAD (from original script logic)
# =============================================================================
v6_load_domains() {
    log_i "Phase 6: Loading domain list..."
    DOMAINS_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    DOMAINS_TMP="/tmp/dnsmasq.d/domains.lst"
    mkdir -p /tmp/dnsmasq.d

    log_i "Downloading domains list..."
    if ! curl -f -s --max-time 120 -o "$DOMAINS_TMP" "$DOMAINS_URL" 2>/dev/null; then
        log_w "Domain list download failed"
        return 1
    fi
    if [ ! -s "$DOMAINS_TMP" ]; then
        log_w "Domain list file empty"
        return 1
    fi

    # Проверка синтаксиса dnsmasq
    if dnsmasq --conf-file="$DOMAINS_TMP" --test 2>&1 | grep -q "syntax check OK"; then
        /etc/init.d/dnsmasq restart 2>/dev/null || true
        log_i "Domain list loaded and dnsmasq restarted."
    else
        log_w "Domain list syntax check failed"
        return 1
    fi
    return 0
}

# =============================================================================
# PHASE 7: IP/SUBNET/COMMUNITY DOWNLOAD & LOAD
# =============================================================================
v6_download_list() {
    dl_name="$1"; dl_set="$2"; dl_base="${3:-https://antifilter.download}"
    dl_url="${dl_base}/list/${dl_name}.lst"
    dl_tmp="/tmp/lst/${dl_set}.lst"
    mkdir -p /tmp/lst

    log_i "Downloading ${dl_name}.lst..."
    if ! curl -f -s --max-time 120 -o "$dl_tmp" "$dl_url" 2>/dev/null; then
        log_w "Download failed: ${dl_name}"; return 1
    fi
    [ -s "$dl_tmp" ] || { log_w "File empty: ${dl_name}"; return 1; }
    log_i "Downloaded ${dl_name} ($(wc -l < "$dl_tmp") lines)."
    return 0
}

v6_load_batch() {
    ld_set="$1"
    ld_src="/tmp/lst/${ld_set}.lst"
    ld_valid="/tmp/lst/${ld_set}.valid"
    ld_batch="/tmp/lst/batch.nft"
    
    log_i "Parsing & loading ${ld_set}..."
    [ -f "$ld_src" ] || { log_w "Source missing: $ld_src"; return 1; }

    # Очистка от мусора, сортировка, удаление дублей
    sed 's/\r//g' "$ld_src" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?' | sort -u > "$ld_valid" 2>/dev/null || true

    if [ ! -s "$ld_valid" ]; then
        log_w "No valid IPs for ${ld_set}"
        rm -f "$ld_src" "$ld_valid" "$ld_batch"
        return 1
    fi

    log_i "Loading $(wc -l < "$ld_valid") unique entries..."
    nft flush set inet fw4 "$ld_set" 2>/dev/null || true
    ld_cnt=0; ld_b=""; ld_done=0

    while IFS= read -r ld_l; do
        [ -z "$ld_l" ] && continue
        [ -z "$ld_b" ] && ld_b="$ld_l" || ld_b="${ld_b}, ${ld_l}"
        ld_cnt=$((ld_cnt + 1))
        if [ "$ld_cnt" -ge 500 ]; then
            printf 'add element inet fw4 %s { %s }\n' "$ld_set" "$ld_b" > "$ld_batch"
            nft -f "$ld_batch" 2>/dev/null && ld_done=$((ld_done + ld_cnt))
            ld_b=""; ld_cnt=0
        fi
    done < "$ld_valid"

    if [ -n "$ld_b" ]; then
        printf 'add element inet fw4 %s { %s }\n' "$ld_set" "$ld_b" > "$ld_batch"
        nft -f "$ld_batch" 2>/dev/null && ld_done=$((ld_done + ld_cnt))
    fi

    rm -f "$ld_src" "$ld_valid" "$ld_batch"
    log_i "Loaded ~${ld_done} entries into ${ld_set}."
    return 0
}

v6_load_all_lists() {
    log_i "Phase 7: Parallel download & sequential load (IP/Subnet/Community)..."
    v6_download_list "ip" "vpn_ip" "https://antifilter.download" &
    pid_ip=$!
    v6_download_list "subnet" "vpn_subnets" "https://antifilter.download" &
    pid_sub=$!
    v6_download_list "community" "vpn_community" "https://community.antifilter.download" &
    pid_comm=$!

    wait $pid_ip 2>/dev/null || log_w "list_ip download failed"
    wait $pid_sub 2>/dev/null || log_w "list_subnet download failed"
    wait $pid_comm 2>/dev/null || log_w "list_community download failed"

    v6_load_batch "vpn_ip"
    v6_load_batch "vpn_subnets"
    v6_load_batch "vpn_community"
}

# =============================================================================
# PHASE 8: MARKING RULES & PERSISTENCE
# =============================================================================
v6_apply_rules() {
    log_i "Phase 8: Applying marking rules & persistence..."
    h_path="/usr/sbin/apply-vpn-mark-rules.sh"
    
    # Создаём helper с проверкой на дубликаты
    printf '%s\n' '#!/bin/sh' \
        '[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0' \
        'for v6c in prerouting output; do' \
        '    for v6s in vpn_domains vpn_ip vpn_subnets vpn_community; do' \
        '        nft list chain inet fw4 "$v6c" 2>/dev/null | grep -q "v6_${v6s}_${v6c}" || \' \
        '            nft add rule inet fw4 "$v6c" ip daddr @"$v6s" meta mark set 0x1 comment "v6_${v6s}_${v6c}" 2>/dev/null || true' \
        '    done' \
        'done' > "$h_path"
    chmod +x "$h_path"

    # Регистрируем в UCI
    if ! uci show firewall 2>/dev/null | grep -q "apply-vpn-mark-rules"; then
        uci add firewall include >/dev/null 2>&1
        uci set firewall.@include[-1].type='script'
        uci set firewall.@include[-1].path="$h_path"
        uci set firewall.@include[-1].reload='1'
        uci commit firewall >/dev/null 2>&1
    fi
    
    "$h_path"
    log_i "Marking rules active & persistence registered."
}

# =============================================================================
# PHASE 9: CRON & FINALIZATION
# =============================================================================
v6_cron() {
    log_i "Phase 9: Configuring cron..."
    cr_cmd="0 */12 * * * /etc/init.d/v6-unified-routing start"
    cr_cur=$(crontab -l 2>/dev/null) || cr_cur=""
    echo "$cr_cur" | grep -q "v6-unified-routing" 2>/dev/null && return 0
    { echo "$cr_cur"; echo "$cr_cmd"; } | crontab - 2>/dev/null || log_w "Failed to update crontab"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
}

# =============================================================================
# MAIN ORCHESTRATOR
# =============================================================================
v6_main() {
    echo "============================================================"
    echo "  Unified Routing v6.0 (Domains + IP/Subnet/Community)"
    echo "  Sing-Box focused, Self-Healing, Stream-Safe"
    echo "============================================================"
    
    v6_cleanup
    v6_validate
    v6_setup_singbox
    v6_setup_firewall
    v6_setup_dns
    v6_load_domains          # Домены из оригинального скрипта
    v6_load_all_lists        # IP/Subnet/Community из моего скрипта
    v6_apply_rules
    v6_cron
    
    log_i "Reloading firewall & network..."
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    
    echo "============================================================"
    log_i "DONE. System is clean, Sing-Box active, routing ready."
    echo "Verify:"
    echo "  • Domains:  nft list set inet fw4 vpn_domains | head"
    echo "  • IP lists: nft list sets | grep vpn_"
    echo "  • Rules:    nft list ruleset | grep 'v6_'"
    echo "============================================================"
}

# =============================================================================
# DISPATCHER (Stream-Safe)
# =============================================================================
v6_cmd="${1:-start}"
if [ "$v6_cmd" = "start" ]; then
    v6_main
elif [ "$v6_cmd" = "clean" ]; then
    v6_cleanup; log_i "Cleanup done."
elif [ "$v6_cmd" = "stop" ]; then
    log_i "Clearing sets..."; for cs in vpn_ip vpn_subnets vpn_community vpn_domains; do nft flush set inet fw4 "$cs" 2>/dev/null || true; done
elif [ "$v6_cmd" = "reload" ] || [ "$v6_cmd" = "restart" ]; then
    "$0" stop; sleep 1; "$0" start
else
    echo "Usage: $0 {start|clean|stop|reload|restart}"; exit 1
fi
exit 0