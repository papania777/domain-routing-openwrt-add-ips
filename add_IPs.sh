#!/bin/sh
# add-ip-subnet-routing-v4.8-turbo.sh
# Оптимизации: параллельные загрузки, батчи по 500, прямые nft add без проверок
# Совместимость: 100% с sh <(wget -O - URL) на OpenWrt ash
# Требуется: OpenWrt 23.05+, 256MB RAM, curl, nftables

GREEN='\033[32;1m'; RED='\033[31;1m'; YELLOW='\033[33;1m'; NC='\033[0m'
log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# =============================================================================
# 1. Проверка зависимостей (без изменений)
# =============================================================================
check_prereqs() {
    log_info "Checking prerequisites..."
    command -v curl >/dev/null 2>&1 || { log_error "curl missing"; exit 1; }
    command -v nft  >/dev/null 2>&1 || { log_error "nft missing"; exit 1; }
    nft list table inet fw4 >/dev/null 2>&1 || { log_error "Table inet fw4 not found"; exit 1; }
    grep -q "99 vpn" /etc/iproute2/rt_tables 2>/dev/null || {
        log_info "Adding '99 vpn' to rt_tables"
        echo '99 vpn' >> /etc/iproute2/rt_tables
    }
    log_info "Prerequisites OK."
}

# =============================================================================
# 2. Создание sets (без изменений)
# =============================================================================
create_sets() {
    log_info "Preparing nft sets..."
    for s in vpn_ip vpn_subnets vpn_community; do
        nft list set inet fw4 "$s" >/dev/null 2>&1 || \
            nft add set inet fw4 "$s" '{ type ipv4_addr; flags interval; }' 2>/dev/null || {
                log_error "Failed to create set $s"; exit 1
            }
    done
}

# =============================================================================
# 3. Очистка legacy UCI (без изменений)
# =============================================================================
cleanup_legacy_uci() {
    log_info "Checking for legacy ipset UCI rules..."
    legacy_rules=""
    legacy_rules=$(uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_" | cut -d= -f1 | cut -d. -f2)
    [ -z "$legacy_rules" ] && return 0
    for r in $legacy_rules; do
        uci delete firewall."$r" >/dev/null 2>&1
    done
    uci commit firewall >/dev/null 2>&1
}

# =============================================================================
# 4. ОПТИМИЗИРОВАННАЯ загрузка: параллельные curl + батчи по 500
# =============================================================================
load_list_fast() {
    ll_name="$1"; ll_set="$2"; ll_base="${3:-https://antifilter.download}"
    ll_url="${ll_base}/list/${ll_name}.lst"
    ll_tmp="/tmp/lst/${ll_name}.lst"
    ll_valid="/tmp/lst/${ll_name}.valid"
    ll_batch="/tmp/lst/batch.nft"
    mkdir -p /tmp/lst

    log_info "Downloading ${ll_name}.lst..."
    curl -f -s --max-time 120 -o "$ll_tmp" "$ll_url" 2>/dev/null || { log_error "Download failed"; return 1; }
    [ -s "$ll_tmp" ] || { log_error "File empty"; return 1; }

    log_info "Flushing set ${ll_set}..."
    nft flush set inet fw4 "${ll_set}" 2>/dev/null || true

    log_info "Filtering valid IPs..."
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$' "$ll_tmp" > "$ll_valid" 2>/dev/null || true
    [ -s "$ll_valid" ] || { log_warn "No valid entries"; rm -f "$ll_tmp" "$ll_valid" "$ll_batch"; return 1; }

    log_info "Loading entries (batch: 500)..."
    ll_cnt=0; ll_b="" ; ll_done=0

    while IFS= read -r ll_l; do
        [ -z "$ll_l" ] && continue
        [ -z "$ll_b" ] && ll_b="$ll_l" || ll_b="${ll_b}, ${ll_l}"
        ll_cnt=$((ll_cnt + 1))
        if [ "$ll_cnt" -ge 500 ]; then
            printf 'add element inet fw4 %s { %s }\n' "${ll_set}" "${ll_b}" > "${ll_batch}"
            nft -f "${ll_batch}" 2>/dev/null && ll_done=$((ll_done + ll_cnt))
            ll_b=""; ll_cnt=0
        fi
    done < "$ll_valid"

    [ -n "$ll_b" ] && printf 'add element inet fw4 %s { %s }\n' "${ll_set}" "${ll_b}" > "${ll_batch}" && \
        nft -f "${ll_batch}" 2>/dev/null && ll_done=$((ll_done + ll_cnt))

    rm -f "$ll_tmp" "$ll_valid" "$ll_batch"
    log_info "Loaded ~${ll_done} entries into ${ll_set}."
    return 0
}

# =============================================================================
# 5. Параллельная загрузка всех списков
# =============================================================================
load_all_parallel() {
    log_info "Starting parallel downloads..."
    
    # Запускаем все загрузки в фоне
    load_list_fast "ip" "vpn_ip" "https://antifilter.download" &
    pid_ip=$!
    load_list_fast "subnet" "vpn_subnets" "https://antifilter.download" &
    pid_sub=$!
    load_list_fast "community" "vpn_community" "https://community.antifilter.download" &
    pid_comm=$!

    # Ждём завершения всех
    wait $pid_ip 2>/dev/null || log_warn "list_ip failed"
    wait $pid_sub 2>/dev/null || log_warn "list_subnet failed"
    wait $pid_comm 2>/dev/null || log_warn "list_community failed"
    
    log_info "All downloads completed."
}

# =============================================================================
# 6. ОПТИМИЗИРОВАННЫЕ правила: прямые nft add без проверок
# =============================================================================
apply_mark_rules() {
    log_info "Applying nft marking rules (optimized)..."
    
    # Создаём helper-скрипт (без heredoc, через printf)
    printf '%s\n' '#!/bin/sh' \
        '[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0' \
        'for amr_c in prerouting output; do' \
        '    for amr_s in vpn_domains vpn_ip vpn_subnets vpn_community; do' \
        '        nft add rule inet fw4 "$amr_c" ip daddr @"$amr_s" meta mark set 0x1 comment "mark_${amr_s}_${amr_c}" 2>/dev/null || true' \
        '    done' \
        'done' > /usr/sbin/apply-vpn-mark-rules.sh
    chmod +x /usr/sbin/apply-vpn-mark-rules.sh

    # Регистрируем в UCI (только если ещё нет)
    if ! uci show firewall 2>/dev/null | grep -q "apply-vpn-mark-rules"; then
        uci add firewall include >/dev/null 2>&1
        uci set firewall.@include[-1].type='script'
        uci set firewall.@include[-1].path='/usr/sbin/apply-vpn-mark-rules.sh'
        uci set firewall.@include[-1].reload='1'
        uci commit firewall >/dev/null 2>&1
    fi
    
    /usr/sbin/apply-vpn-mark-rules.sh
    log_info "Marking rules active."
}

# =============================================================================
# 7. Cron (без изменений)
# =============================================================================
setup_cron() {
    cron_cmd="0 */12 * * * /etc/init.d/add-ip-subnet-routing start"
    cron_cur=$(crontab -l 2>/dev/null) || cron_cur=""
    echo "$cron_cur" | grep -q "add-ip-subnet-routing" 2>/dev/null && return 0
    { echo "$cron_cur"; echo "$cron_cmd"; } | crontab - 2>/dev/null || log_warn "Crontab update failed"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
}

# =============================================================================
# MAIN
# =============================================================================
main_entry() {
    echo "============================================================"
    echo "  Add IP/Subnet/Community Routing v4.8-turbo"
    echo "  Parallel downloads, batch=500, direct nft add"
    echo "============================================================"
    
    check_prereqs || exit 1
    cleanup_legacy_uci
    create_sets
    
    # Замер времени загрузки
    log_info "Starting optimized load..."
    time_start=$(date +%s)
    
    load_all_parallel
    
    time_end=$(date +%s)
    time_diff=$((time_end - time_start))
    log_info "All lists loaded in ${time_diff} seconds."
    
    apply_mark_rules
    setup_cron
    
    log_info "Reloading firewall..."
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    
    echo "============================================================"
    log_info "DONE. Total time: ~$((time_diff + 2)) seconds."
    echo "============================================================"
}

# =============================================================================
# Dispatcher (flat, stream-safe)
# =============================================================================
cmd="${1:-start}"
if [ "$cmd" = "start" ]; then
    main_entry
elif [ "$cmd" = "stop" ]; then
    log_info "Clearing sets..."
    for cs in vpn_ip vpn_subnets vpn_community; do
        nft flush set inet fw4 "$cs" 2>/dev/null || true
    done
elif [ "$cmd" = "reload" ] || [ "$cmd" = "restart" ]; then
    "$0" stop; sleep 1; "$0" start
else
    echo "Usage: $0 {start|stop|reload|restart}"; exit 1
fi
exit 0