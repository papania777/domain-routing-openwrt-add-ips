#!/bin/sh
# =============================================================================
# add-ip-subnet-routing-v4.1.sh (Optimized + Community List)
# Добавляет list_ip, list_subnet, list_community в domain-routing-openwrt
# Источник community: https://community.antifilter.download/list/community.lst
# Оптимизация: awk + nft -f (загрузка 43k IP за ~2 сек)
# Совместимость: OpenWrt 23.05+, fw4 (nftables), 256MB RAM
# =============================================================================

GREEN='\033[32;1m'
RED='\033[31;1m'
YELLOW='\033[33;1m'
NC='\033[0m'

log_info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# =============================================================================
# 1. Проверка зависимостей
# =============================================================================
check_prereqs() {
    log_info "Checking prerequisites..."
    command -v curl >/dev/null 2>&1 || { log_error "curl missing"; exit 1; }
    command -v nft  >/dev/null 2>&1 || { log_error "nft missing"; exit 1; }
    nft list table inet fw4 >/dev/null 2>&1 || { log_error "Table inet fw4 not found. Run main script first."; exit 1; }
    grep -q "^[[:space:]]*99[[:space:]]\+vpn" /etc/iproute2/rt_tables 2>/dev/null || {
        log_info "Adding '99 vpn' to rt_tables"; echo '99 vpn' >> /etc/iproute2/rt_tables
    }
    log_info "Prerequisites OK."
}

# =============================================================================
# 2. Создание nft sets (idempotent)
# =============================================================================
create_sets() {
    log_info "Preparing nft sets..."
    for set in vpn_ip vpn_subnets vpn_community; do
        if nft list set inet fw4 "$set" >/dev/null 2>&1; then
            log_info "Set '$set' exists."
        else
            nft add set inet fw4 "$set" '{ type ipv4_addr; flags interval; }' 2>/dev/null || {
                log_error "Failed to create set '$set'"; exit 1
            }
        fi
    done
}

# =============================================================================
# 3. Очистка устаревших UCI-правил с параметром 'ipset' (КРИТИЧЕСКИЙ ФИКС)
# =============================================================================
cleanup_legacy_uci() {
    log_info "Checking for legacy 'ipset' UCI rules..."
    local found=0
    for rule in $(uci show firewall 2>/dev/null | grep -E "@rule\[.*\]\.ipset='vpn_" | cut -d= -f1 | cut -d. -f2); do
        log_info "Deleting legacy rule: $rule (ipset -> set migration)"
        uci delete firewall."$rule" >/dev/null 2>&1
        found=1
    done
    if [ "$found" -eq 1 ]; then
        uci commit firewall >/dev/null 2>&1
        log_info "Legacy rules removed."
    fi
}

# =============================================================================
# 4. Оптимизированная загрузка списков (awk + nft -f)
# =============================================================================
load_list_fast() {
    local list_name="$1" set_name="$2" url_base="${3:-https://antifilter.download}"
    local url="${url_base}/list/${list_name}.lst"
    local tmp="/tmp/lst/${list_name}.lst"
    local nft_cmd="/tmp/lst/${list_name}.nft"
    mkdir -p /tmp/lst

    log_info "Downloading ${list_name}.lst from ${url_base}..."
    curl -f -s --max-time 120 -o "$tmp" "$url" 2>/dev/null || { log_error "Download failed: $url"; return 1; }
    [ -s "$tmp" ] || { log_error "File empty: $tmp"; return 1; }

    log_info "Flushing set '$set_name'..."
    nft flush set inet fw4 "$set_name" 2>/dev/null || true

    log_info "Converting and loading via awk + nft -f (optimized)..."
    # POSIX-совместимый awk для BusyBox
    awk -v set="$set_name" '
    BEGIN { c=0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
        gsub(/[[:space:]]/, "")
        if ($0 ~ /^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*(\/[0-9][0-9]*)?$/) {
            if (c == 0) printf "add element inet fw4 %s { %s", set, $0
            else printf ", %s", $0
            c++
            if (c == 2000) { printf "\n}\n"; c=0 }
        }
    }
    END { if (c > 0) printf "\n}\n" }
    ' "$tmp" > "$nft_cmd"

    if [ ! -s "$nft_cmd" ]; then
        log_warn "No valid entries found in ${list_name}.lst"
        rm -f "$nft_cmd" "$tmp"
        return 1
    fi

    log_info "Executing bulk nft load..."
    if nft -f "$nft_cmd" 2>/dev/null; then
        log_info "Successfully loaded entries into '$set_name'."
    else
        log_warn "nft -f failed. Fallback to line-by-line (slow)..."
        grep -oE '[0-9.]+(/[0-9]+)?' "$nft_cmd" 2>/dev/null | tr -d '{}' | while read -r ip; do
            nft add element inet fw4 "$set_name" "{ $ip }" 2>/dev/null || true
        done
    fi

    rm -f "$nft_cmd" "$tmp"
    return 0
}

# =============================================================================
# 5. Применение прямых nft-правил + persistence
# =============================================================================
apply_mark_rules() {
    log_info "Applying direct nft marking rules..."
    
    cat > /usr/sbin/apply-vpn-mark-rules.sh << 'HELPER_EOF'
#!/bin/sh
[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0
add_if_missing() {
    nft list chain inet fw4 "$1" 2>/dev/null | grep -q "$2" || \
        nft add rule inet fw4 "$1" ip daddr "$3" meta mark set 0x1 comment "$2" 2>/dev/null
}
# Domains
add_if_missing prerouting "mark_vpn_domains_prerouting" "@vpn_domains"
add_if_missing output     "mark_vpn_domains_output"      "@vpn_domains"
# IP
add_if_missing prerouting "mark_vpn_ip_prerouting"       "@vpn_ip"
add_if_missing output     "mark_vpn_ip_output"           "@vpn_ip"
# Subnets
add_if_missing prerouting "mark_vpn_sub_prerouting"      "@vpn_subnets"
add_if_missing output     "mark_vpn_sub_output"          "@vpn_subnets"
# Community
add_if_missing prerouting "mark_vpn_comm_prerouting"     "@vpn_community"
add_if_missing output     "mark_vpn_comm_output"         "@vpn_community"
HELPER_EOF
    chmod +x /usr/sbin/apply-vpn-mark-rules.sh

    if ! uci show firewall 2>/dev/null | grep -q "apply-vpn-mark-rules"; then
        uci add firewall include >/dev/null 2>&1
        uci set firewall.@include[-1].type='script'
        uci set firewall.@include[-1].path='/usr/sbin/apply-vpn-mark-rules.sh'
        uci set firewall.@include[-1].reload='1'
        uci commit firewall >/dev/null 2>&1
        log_info "Persistence helper registered."
    fi

    /usr/sbin/apply-vpn-mark-rules.sh
    log_info "Marking rules active."
}

# =============================================================================
# 6. Cron для автообновления
# =============================================================================
setup_cron() {
    local cmd="0 */12 * * * /etc/init.d/add-ip-subnet-routing start"
    local cur
    cur=$(crontab -l 2>/dev/null) || cur=""
    echo "$cur" | grep -q "add-ip-subnet-routing" 2>/dev/null && return 0
    { echo "$cur"; echo "$cmd"; } | crontab - 2>/dev/null || log_warn "Crontab update failed"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    log_info "Cron configured (every 12h)."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo "============================================================"
    echo "  Add IP/Subnet/Community Routing v4.1 (Optimized)"
    echo "  Fast load (awk+nft), correct chains, persistence"
    echo "============================================================"
    
    check_prereqs || exit 1
    cleanup_legacy_uci
    create_sets
    
    log_info "Checking free RAM..."
    FREE_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || free | awk '/^Mem:/ {print $4}')
    if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 50000 ]; then
        log_warn "Low RAM (${FREE_KB}KB). Loading 4 lists may be slow. Consider stopping heavy services."
    fi

    # Загрузка списков (параллельно не делаем — экономим RAM)
    load_list_fast "ip" "vpn_ip" "https://antifilter.download" || log_warn "list_ip failed"
    load_list_fast "subnet" "vpn_subnets" "https://antifilter.download" || log_warn "list_subnet failed"
    load_list_fast "community" "vpn_community" "https://community.antifilter.download" || log_warn "list_community failed"
    
    apply_mark_rules
    setup_cron
    
    log_info "Final firewall reload..."
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    
    echo "============================================================"
    log_info "DONE. Verify with commands below."
    echo "============================================================"
}

# =============================================================================
# Init interface
# =============================================================================
case "${1:-start}" in
    start) main ;;
    stop)
        log_info "Clearing sets..."
        nft flush set inet fw4 vpn_ip 2>/dev/null || true
        nft flush set inet fw4 vpn_subnets 2>/dev/null || true
        nft flush set inet fw4 vpn_community 2>/dev/null || true
        ;;
    reload|restart) "$0" stop; sleep 1; "$0" start ;;
    *) echo "Usage: $0 {start|stop|reload|restart}"; exit 1 ;;
esac
exit 0