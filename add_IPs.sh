#!/bin/sh
# =============================================================================
# add-ip-subnet-routing-v4.2-hotfix.sh
# Исправлено: удалён bash-синтаксис, полная совместимость с ash/OpenWrt
# Оптимизация: awk + nft -f, батч 500 записей, fallback через temp-файл
# Совместимость: OpenWrt 23.05/24.10, fw4, nftables 1.0.9+, 256MB RAM
# =============================================================================

GREEN='\033[32;1m'; RED='\033[31;1m'; YELLOW='\033[33;1m'; NC='\033[0m'
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
    nft list table inet fw4 >/dev/null 2>&1 || { log_error "Table inet fw4 not found"; exit 1; }
    grep -q "^[[:space:]]*99[[:space:]]\+vpn" /etc/iproute2/rt_tables 2>/dev/null || {
        log_info "Adding '99 vpn' to rt_tables"; echo '99 vpn' >> /etc/iproute2/rt_tables
    }
    NFT_VER=$(nft --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$NFT_VER" ] && log_info "nftables $NFT_VER detected"
    log_info "Prerequisites OK."
}

# =============================================================================
# 2. Создание nft sets
# =============================================================================
create_sets() {
    log_info "Preparing nft sets..."
    for set in vpn_ip vpn_subnets vpn_community; do
        if ! nft list set inet fw4 "$set" >/dev/null 2>&1; then
            nft add set inet fw4 "$set" '{ type ipv4_addr; flags interval; }' 2>/dev/null || {
                log_error "Failed to create set '$set'"; exit 1
            }
        fi
    done
}

# =============================================================================
# 3. Очистка legacy UCI-правил
# =============================================================================
cleanup_legacy_uci() {
    log_info "Checking for legacy 'ipset' UCI rules..."
    for rule in $(uci show firewall 2>/dev/null | grep -E "@rule\[.*\]\.ipset='vpn_" | cut -d= -f1 | cut -d. -f2); do
        log_info "Deleting legacy rule: $rule"
        uci delete firewall."$rule" >/dev/null 2>&1
    done
    uci commit firewall >/dev/null 2>&1
}

# =============================================================================
# 4. Оптимизированная загрузка (POSIX-совместимая)
# =============================================================================
load_list_fast() {
    local list_name="$1" set_name="$2" url_base="${3:-https://antifilter.download}"
    local url="${url_base}/list/${list_name}.lst"
    local tmp="/tmp/lst/${list_name}.lst"
    local nft_cmd="/tmp/lst/${list_name}.nft"
    local valid_ips="/tmp/lst/${list_name}.valid"
    mkdir -p /tmp/lst

    log_info "Downloading ${list_name}.lst..."
    curl -f -s --max-time 120 -o "$tmp" "$url" 2>/dev/null || { log_error "Download failed: $url"; return 1; }
    [ -s "$tmp" ] || { log_error "File empty: $tmp"; return 1; }

    log_info "Flushing set '$set_name'..."
    nft flush set inet fw4 "$set_name" 2>/dev/null || true

    log_info "Converting entries via awk (batch: 500)..."
    # Генерация команд nft с батчами по 500 записей
    awk -v set="$set_name" '
    BEGIN { c=0; batch=0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
        gsub(/[[:space:]]/, "")
        if ($0 ~ /^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*(\/[0-9][0-9]*)?$/) {
            if (c == 0) { if (batch > 0) printf "\n}\n"; printf "add element inet fw4 %s { %s", set, $0 }
            else printf ", %s", $0
            c++; batch++
            if (batch == 500) { printf "\n}\n"; c=0; batch=0 }
        }
    }
    END { if (c > 0) printf "\n}\n" }
    ' "$tmp" > "$nft_cmd"

    if [ ! -s "$nft_cmd" ]; then
        log_warn "No valid entries found in ${list_name}.lst"
        rm -f "$nft_cmd" "$tmp" "$valid_ips"
        return 1
    fi

    log_info "Loading via nft -f..."
    NFT_ERR=$(nft -f "$nft_cmd" 2>&1)
    if [ $? -eq 0 ]; then
        log_info "Loaded '$set_name' via nft -f."
    else
        log_warn "nft -f failed: $NFT_ERR"
        log_info "Fallback: batched load via temp file..."
        
        # === ИСПРАВЛЕНИЕ: вместо < <(...) используем временный файл ===
        # Извлекаем валидные IP в отдельный файл
        grep -oE '^[0-9.]+(/[0-9]{1,2})?$' "$tmp" 2>/dev/null > "$valid_ips" || true
        
        if [ -s "$valid_ips" ]; then
            local batch="" cnt=0
            while IFS= read -r ip; do
                [ -z "$ip" ] && continue
                [ -z "$batch" ] && batch="$ip" || batch="${batch}, ${ip}"
                cnt=$((cnt + 1))
                if [ $cnt -ge 100 ]; then
                    nft add element inet fw4 "$set_name" "{ $batch }" 2>/dev/null || true
                    batch="" cnt=0
                fi
            done < "$valid_ips"
            [ -n "$batch" ] && nft add element inet fw4 "$set_name" "{ $batch }" 2>/dev/null || true
            log_info "Fallback load completed for '$set_name'."
        else
            log_warn "No valid IPs extracted for fallback"
        fi
        rm -f "$valid_ips"
    fi
    
    rm -f "$nft_cmd" "$tmp"
    return 0
}

# =============================================================================
# 5. Применение правил маркировки + persistence
# =============================================================================
apply_mark_rules() {
    log_info "Applying nft marking rules..."
    
    cat > /usr/sbin/apply-vpn-mark-rules.sh << 'HELPER_EOF'
#!/bin/sh
[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0
add_if_missing() {
    nft list chain inet fw4 "$1" 2>/dev/null | grep -q "$2" || \
        nft add rule inet fw4 "$1" ip daddr "$3" meta mark set 0x1 comment "$2" 2>/dev/null || true
}
for chain in prerouting output; do
    add_if_missing "$chain" "mark_vpn_domains_${chain}" "@vpn_domains"
    add_if_missing "$chain" "mark_vpn_ip_${chain}"       "@vpn_ip"
    add_if_missing "$chain" "mark_vpn_sub_${chain}"      "@vpn_subnets"
    add_if_missing "$chain" "mark_vpn_comm_${chain}"     "@vpn_community"
done
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
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo "============================================================"
    echo "  Add IP/Subnet/Community Routing v4.2-hotfix"
    echo "  POSIX-compatible (ash), nftables 1.0.9+ ready"
    echo "============================================================"
    
    check_prereqs || exit 1
    cleanup_legacy_uci
    create_sets
    
    log_info "Checking free RAM..."
    FREE_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || free | awk '/^Mem:/ {print $4}')
    if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 50000 ]; then
        log_warn "Low RAM (${FREE_KB}KB). Loading may be slower."
    fi

    load_list_fast "ip" "vpn_ip" "https://antifilter.download" || log_warn "list_ip failed"
    load_list_fast "subnet" "vpn_subnets" "https://antifilter.download" || log_warn "list_subnet failed"
    load_list_fast "community" "vpn_community" "https://community.antifilter.download" || log_warn "list_community failed"
    
    apply_mark_rules
    setup_cron
    
    log_info "Final firewall reload..."
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    
    echo "============================================================"
    log_info "DONE. Verify: nft list sets | grep vpn_"
    echo "============================================================"
}

# =============================================================================
# Init interface
# =============================================================================
case "${1:-start}" in
    start) main ;;
    stop)
        log_info "Clearing sets..."
        for s in vpn_ip vpn_subnets vpn_community; do
            nft flush set inet fw4 "$s" 2>/dev/null || true
        done
        ;;
    reload|restart) "$0" stop; sleep 1; "$0" start ;;
    *) echo "Usage: $0 {start|stop|reload|restart}"; exit 1 ;;
esac
exit 0