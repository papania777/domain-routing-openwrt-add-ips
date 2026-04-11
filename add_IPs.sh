#!/bin/sh
# =============================================================================
# add-ip-subnet-routing-v4.3.sh (Memory-Safe + Production Ready)
# Добавляет list_ip, list_subnet, list_community в domain-routing-openwrt
# Исправлено: 
#   - Устранена ошибка "Killed" (OOM/netlink) через потоковую загрузку батчами
#   - Удалены legacy UCI-правила с параметром 'ipset' (причина "весь трафик в VPN")
#   - Полная POSIX/ash совместимость (OpenWrt 23.05/24.10, fw4)
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
    
    # Проверка таблицы маршрутизации (используем -E для совместимости с BusyBox grep)
    grep -qE "^[[:space:]]*99[[:space:]]+vpn" /etc/iproute2/rt_tables 2>/dev/null || {
        log_info "Adding '99 vpn' to rt_tables"
        echo '99 vpn' >> /etc/iproute2/rt_tables
    }
    log_info "Prerequisites OK."
}

# =============================================================================
# 2. Создание nft sets (idempotent)
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
# 3. Очистка устаревших UCI-правил с параметром 'ipset'
# =============================================================================
cleanup_legacy_uci() {
    log_info "Checking for legacy 'ipset' UCI rules..."
    local found=0
    for rule in $(uci show firewall 2>/dev/null | grep -E "@rule\[.*\]\.ipset='vpn_" | cut -d= -f1 | cut -d. -f2); do
        log_info "Deleting legacy rule: $rule"
        uci delete firewall."$rule" >/dev/null 2>&1
        found=1
    done
    [ "$found" -eq 1 ] && uci commit firewall >/dev/null 2>&1
}

# =============================================================================
# 4. Загрузка списков (Memory-Safe, потоковая обработка)
# =============================================================================
load_list_fast() {
    local list_name="$1" set_name="$2" url_base="${3:-https://antifilter.download}"
    local url="${url_base}/list/${list_name}.lst"
    local tmp="/tmp/lst/${list_name}.lst"
    local batch_file="/tmp/lst/batch.nft"
    mkdir -p /tmp/lst

    log_info "Downloading ${list_name}.lst..."
    curl -f -s --max-time 120 -o "$tmp" "$url" 2>/dev/null || { log_error "Download failed: $url"; return 1; }
    [ -s "$tmp" ] || { log_error "File empty: $tmp"; return 1; }

    log_info "Flushing set '$set_name'..."
    nft flush set inet fw4 "$set_name" 2>/dev/null || true

    log_info "Loading entries (memory-optimized, batch: 100)..."
    local count=0 batch="" loaded=0

    # POSIX-совместимое построчное чтение
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in \#*|"") continue ;; esac
        # Удаляем пробелы, табуляции и CR
        line=$(echo "$line" | tr -d ' \t\r')
        [ -z "$line" ] && continue
        
        # Быстрая валидация IPv4/CIDR
        echo "$line" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' || continue

        [ -z "$batch" ] && batch="$line" || batch="${batch}, ${line}"
        count=$((count + 1))

        # Отправка батча каждые 100 элементов
        if [ $count -ge 100 ]; then
            printf "add element inet fw4 %s { %s }\n" "$set_name" "$batch" > "$batch_file"
            if nft -f "$batch_file" 2>/dev/null; then
                loaded=$((loaded + count))
            else
                log_warn "Failed to load batch for $set_name"
            fi
            batch=""
            count=0
            # Небольшая задержка не требуется: вызов nft -f уже сбрасывает netlink-буфер
        fi
    done < "$tmp"

    # Отправка остатка
    if [ -n "$batch" ]; then
        printf "add element inet fw4 %s { %s }\n" "$set_name" "$batch" > "$batch_file"
        nft -f "$batch_file" 2>/dev/null && loaded=$((loaded + count))
    fi

    rm -f "$tmp" "$batch_file"
    log_info "Successfully loaded ~$loaded entries into '$set_name'."
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
        log_info "Persistence helper registered in UCI."
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
    echo "  Add IP/Subnet/Community Routing v4.3 (Memory-Safe)"
    echo "  Streaming loader, no OOM, fw4/nft compatible"
    echo "============================================================"

    check_prereqs || exit 1
    cleanup_legacy_uci
    create_sets

    log_info "Checking free RAM..."
    local free_mb
    free_mb=$(awk '/^MemAvailable:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || free -m | awk '/^Mem:/ {print $4}')
    if [ -n "$free_mb" ] && [ "$free_mb" -lt 50 ]; then
        log_warn "Low RAM (${free_mb}MB). Loading will proceed safely, but may take slightly longer."
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