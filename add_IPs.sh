#!/bin/sh
# =============================================================================
# add-ip-subnet-routing-v5.0-omnibus.sh
# Self-Healing, Stream-Safe, Optimized Routing Installer
# Автоматически очищает старые версии, чинит систему, применяет правила
# Совместимость: OpenWrt 23.05/24.10, ash (stream), fw4/nft, 256MB RAM
# =============================================================================

GREEN='\033[32;1m'; RED='\033[31;1m'; YELLOW='\033[33;1m'; NC='\033[0m'
log_i() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_w() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_e() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# =============================================================================
# PHASE 1: DEEP CLEANUP & MIGRATION
# =============================================================================
v5_cleanup() {
    log_i "Phase 1: Deep cleanup & migration..."
    
    # 1. Очистка cron
    cr_cur=$(crontab -l 2>/dev/null) || cr_cur=""
    cr_new=$(echo "$cr_cur" | grep -v "add-ip-subnet-routing")
    if [ "$cr_cur" != "$cr_new" ]; then
        echo "$cr_new" | crontab - 2>/dev/null || true
        log_i "Cleared old cron entries."
    fi

    # 2. Удаление старых UCI-правил firewall (ipset, set, include)
    uci_rules=$(uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_|\.set='vpn_|path.*apply-vpn-mark-rules")
    if [ -n "$uci_rules" ]; then
        for r in $(echo "$uci_rules" | cut -d= -f1 | cut -d. -f2); do
            uci delete firewall."$r" >/dev/null 2>&1 || true
        done
        uci commit firewall >/dev/null 2>&1
        log_i "Cleared legacy UCI firewall rules."
    fi

    # 3. Удаление старых helper-скриптов и init-скриптов
    rm -f /usr/sbin/apply-vpn-mark-rules.sh /etc/init.d/add-ip-subnet-routing
    rm -f /etc/init.d/getdomains 2>/dev/null || true # Если был модифицирован вручную

    # 4. Очистка nft sets (flush, не delete, чтобы сохранить структуру fw4)
    for s in vpn_ip vpn_subnets vpn_community vpn_domains; do
        nft flush set inet fw4 "$s" 2>/dev/null || true
    done
    log_i "Flushed nft sets."

    # 5. Очистка временных файлов
    rm -rf /tmp/lst/* /tmp/batch.nft /tmp/routing-v*.sh /tmp/add*.sh
    log_i "Cleared temp files."
    log_i "Cleanup completed."
}

# =============================================================================
# PHASE 2: SYSTEM VALIDATION & REPAIR
# =============================================================================
v5_validate() {
    log_i "Phase 2: System validation & repair..."
    
    # Зависимости
    if ! command -v curl >/dev/null 2>&1; then log_e "curl missing. Install via opkg."; exit 1; fi
    if ! command -v nft  >/dev/null 2>&1; then log_e "nft missing. Install via opkg."; exit 1; fi
    if ! nft list table inet fw4 >/dev/null 2>&1; then log_e "Table inet fw4 not found. Install firewall4."; exit 1; fi

    # Исправление rt_tables (удаление дублей, добавление 99 vpn)
    if grep -q "^[[:space:]]*99[[:space:]]*vpn" /etc/iproute2/rt_tables 2>/dev/null; then
        sed -i '/^[[:space:]]*99[[:space:]]*vpn/d' /etc/iproute2/rt_tables 2>/dev/null || true
    fi
    echo '99 vpn' >> /etc/iproute2/rt_tables
    log_i "Fixed rt_tables (99 vpn)."

    # Проверка/создание правила маркировки в network UCI
    if ! uci show network 2>/dev/null | grep -q "mark='0x1'"; then
        uci add network rule >/dev/null 2>&1
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit network
        log_i "Created network routing rule (mark0x1)."
    else
        log_i "Network routing rule (mark0x1) exists."
    fi
    log_i "Validation completed."
}

# =============================================================================
# PHASE 3: CORE SETUP & PARALLEL DOWNLOAD
# =============================================================================
v5_download() {
    dl_name="$1"; dl_set="$2"; dl_base="${3:-https://antifilter.download}"
    dl_url="${dl_base}/list/${dl_name}.lst"
    dl_tmp="/tmp/lst/${dl_name}.lst"
    mkdir -p /tmp/lst

    log_i "Downloading ${dl_name}.lst..."
    if ! curl -f -s --max-time 120 -o "$dl_tmp" "$dl_url" 2>/dev/null; then
        log_w "Download failed: ${dl_name}"
        return 1
    fi
    if [ ! -s "$dl_tmp" ]; then
        log_w "File empty: ${dl_name}"
        return 1
    fi
    log_i "Downloaded ${dl_name}."
    return 0
}

v5_load_batch() {
    ld_set="$1"
    ld_valid="/tmp/lst/${ld_set}.valid"
    ld_batch="/tmp/lst/batch.nft"
    
    log_i "Filtering & loading ${ld_set}..."
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$' "/tmp/lst/${ld_set}.lst" > "$ld_valid" 2>/dev/null || true
    if [ ! -s "$ld_valid" ]; then
        log_w "No valid entries for ${ld_set}"
        rm -f "$ld_valid" "$ld_batch"
        return 0
    fi

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

    rm -f "$ld_valid" "$ld_batch" "/tmp/lst/${ld_set}.lst"
    log_i "Loaded ~${ld_done} entries into ${ld_set}."
    return 0
}

# =============================================================================
# PHASE 4: RULES & PERSISTENCE
# =============================================================================
v5_apply_rules() {
    log_i "Phase 4: Applying rules & persistence..."
    
    # Создаём helper через printf (без heredoc, 100% stream-safe)
    h_path="/usr/sbin/apply-vpn-mark-rules.sh"
    printf '%s\n' '#!/bin/sh' \
        '[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0' \
        'for v5c in prerouting output; do' \
        '    for v5s in vpn_domains vpn_ip vpn_subnets vpn_community; do' \
        '        nft add rule inet fw4 "$v5c" ip daddr @"$v5s" meta mark set 0x1 comment "v5_${v5s}_${v5c}" 2>/dev/null || true' \
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
    
    # Применяем сразу
    "$h_path"
    log_i "Marking rules active & persistence registered."
}

# =============================================================================
# PHASE 5: CRON & FINALIZATION
# =============================================================================
v5_cron() {
    log_i "Phase 5: Configuring cron..."
    cr_cmd="0 */12 * * * /etc/init.d/add-ip-subnet-routing start"
    cr_cur=$(crontab -l 2>/dev/null) || cr_cur=""
    if echo "$cr_cur" | grep -q "add-ip-subnet-routing" 2>/dev/null; then
        log_i "Cron already configured."
        return 0
    fi
    if ! { echo "$cr_cur"; echo "$cr_cmd"; } | crontab - 2>/dev/null; then
        log_w "Failed to update crontab."
    fi
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    log_i "Cron set (every 12h)."
}

# =============================================================================
# MAIN ORCHESTRATOR
# =============================================================================
v5_main() {
    echo "============================================================"
    echo "  Routing Installer v5.0-Omnibus (Self-Healing)"
    echo "============================================================"
    
    v5_cleanup
    v5_validate
    
    log_i "Phase 3: Parallel download & load..."
    v5_download "ip" "vpn_ip" "https://antifilter.download" &
    pid_ip=$!
    v5_download "subnet" "vpn_subnets" "https://antifilter.download" &
    pid_sub=$!
    v5_download "community" "vpn_community" "https://community.antifilter.download" &
    pid_comm=$!

    wait $pid_ip 2>/dev/null || log_w "list_ip download failed"
    wait $pid_sub 2>/dev/null || log_w "list_subnet download failed"
    wait $pid_comm 2>/dev/null || log_w "list_community download failed"

    # Загружаем последовательно (экономит RAM, nft работает стабильнее)
    v5_load_batch "vpn_ip"
    v5_load_batch "vpn_subnets"
    v5_load_batch "vpn_community"

    v5_apply_rules
    v5_cron
    
    log_i "Reloading firewall..."
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    
    echo "============================================================"
    log_i "DONE. System is clean, optimized, and routing active."
    echo "Verify: nft list sets | grep vpn_"
    echo "============================================================"
}

# =============================================================================
# DISPATCHER (Stream-Safe)
# =============================================================================
v5_cmd="${1:-start}"
if [ "$v5_cmd" = "start" ]; then
    v5_main
elif [ "$v5_cmd" = "clean" ]; then
    v5_cleanup
    log_i "Cleanup done. Run 'start' to reinstall."
elif [ "$v5_cmd" = "stop" ]; then
    log_i "Clearing sets..."
    for cs in vpn_ip vpn_subnets vpn_community; do
        nft flush set inet fw4 "$cs" 2>/dev/null || true
    done
elif [ "$v5_cmd" = "reload" ] || [ "$v5_cmd" = "restart" ]; then
    "$0" stop; sleep 1; "$0" start
else
    echo "Usage: $0 {start|clean|stop|reload|restart}"
    exit 1
fi
exit 0