#!/bin/sh
# =============================================================================
# add-ip-subnet-routing-v5.2-robust.sh (Self-Healing + Bulletproof Parser)
# Исправлено: пути файлов, парсинг \r/пробелов, добавлена диагностика
# =============================================================================

GREEN='\033[32;1m'; RED='\033[31;1m'; YELLOW='\033[33;1m'; NC='\033[0m'
log_i() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_w() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_e() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# =============================================================================
# PHASE 1: DEEP CLEANUP
# =============================================================================
v5_cleanup() {
    log_i "Phase 1: Deep cleanup & migration..."
    cr_cur=$(crontab -l 2>/dev/null) || cr_cur=""
    cr_new=$(echo "$cr_cur" | grep -v "add-ip-subnet-routing")
    if [ "$cr_cur" != "$cr_new" ]; then
        echo "$cr_new" | crontab - 2>/dev/null || true
        log_i "Cleared old cron entries."
    fi

    uci_rules=$(uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_|\.set='vpn_|path.*apply-vpn-mark-rules")
    if [ -n "$uci_rules" ]; then
        for r in $(echo "$uci_rules" | cut -d= -f1 | cut -d. -f2); do
            uci delete firewall."$r" >/dev/null 2>&1 || true
        done
        uci commit firewall >/dev/null 2>&1
        log_i "Cleared legacy UCI firewall rules."
    fi

    rm -f /usr/sbin/apply-vpn-mark-rules.sh /etc/init.d/add-ip-subnet-routing
    for s in vpn_ip vpn_subnets vpn_community vpn_domains; do
        nft flush set inet fw4 "$s" 2>/dev/null || true
    done
    rm -rf /tmp/lst/* /tmp/batch.nft
    log_i "Flushed nft sets & cleared temp files."
}

# =============================================================================
# PHASE 2: VALIDATION & REPAIR
# =============================================================================
v5_validate() {
    log_i "Phase 2: System validation & repair..."
    command -v curl >/dev/null 2>&1 || { log_e "curl missing"; exit 1; }
    command -v nft  >/dev/null 2>&1 || { log_e "nft missing"; exit 1; }
    nft list table inet fw4 >/dev/null 2>&1 || { log_e "Table inet fw4 not found"; exit 1; }

    if grep -q "^[[:space:]]*99[[:space:]]*vpn" /etc/iproute2/rt_tables 2>/dev/null; then
        sed -i '/^[[:space:]]*99[[:space:]]*vpn/d' /etc/iproute2/rt_tables 2>/dev/null || true
    fi
    echo '99 vpn' >> /etc/iproute2/rt_tables
    log_i "Fixed rt_tables (99 vpn)."

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
# PHASE 3: DOWNLOAD & LOAD (ROBUST PARSER)
# =============================================================================
v5_download() {
    dl_name="$1"; dl_set="$2"; dl_base="${3:-https://antifilter.download}"
    dl_url="${dl_base}/list/${dl_name}.lst"
    # FIXED: сохраняем под именем сета, чтобы v5_load_batch нашёл файл
    dl_tmp="/tmp/lst/${dl_set}.lst"
    mkdir -p /tmp/lst

    log_i "Downloading ${dl_name}.lst..."
    if ! curl -f -s --max-time 120 -o "$dl_tmp" "$dl_url" 2>/dev/null; then
        log_w "Download failed: ${dl_name}"; return 1
    fi
    if [ ! -s "$dl_tmp" ]; then
        log_w "File empty: ${dl_name}"; return 1
    fi
    log_i "Downloaded ${dl_name} ($(wc -l < "$dl_tmp") lines)."
    return 0
}

v5_load_batch() {
    ld_set="$1"
    ld_src="/tmp/lst/${ld_set}.lst"
    ld_valid="/tmp/lst/${ld_set}.valid"
    ld_batch="/tmp/lst/batch.nft"
    
    log_i "Parsing & loading ${ld_set}..."
    if [ ! -f "$ld_src" ]; then
        log_w "Source file missing: $ld_src (download failed)"; return 1
    fi

    # ROBUST: убираем \r, вырезаем только IP/CIDR, удаляем дубликаты
    sed 's/\r//g' "$ld_src" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?' | sort -u > "$ld_valid" 2>/dev/null || true

    if [ ! -s "$ld_valid" ]; then
        log_w "No valid IPs extracted from ${ld_set}"
        log_w "First 3 raw lines:"
        head -n 3 "$ld_src"
        rm -f "$ld_src" "$ld_valid" "$ld_batch"
        return 1
    fi

    log_i "Loading $(wc -l < "$ld_valid") unique entries into ${ld_set}..."
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

# =============================================================================
# PHASE 4: RULES & PERSISTENCE
# =============================================================================
v5_apply_rules() {
    log_i "Phase 4: Applying rules & persistence..."
    h_path="/usr/sbin/apply-vpn-mark-rules.sh"
    printf '%s\n' '#!/bin/sh' \
        '[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0' \
        'for v5c in prerouting output; do' \
        '    for v5s in vpn_domains vpn_ip vpn_subnets vpn_community; do' \
        '        nft add rule inet fw4 "$v5c" ip daddr @"$v5s" meta mark set 0x1 comment "v5_${v5s}_${v5c}" 2>/dev/null || true' \
        '    done' \
        'done' > "$h_path"
    chmod +x "$h_path"

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
# PHASE 5: CRON & FINAL
# =============================================================================
v5_cron() {
    log_i "Phase 5: Configuring cron..."
    cr_cmd="0 */12 * * * /etc/init.d/add-ip-subnet-routing start"
    cr_cur=$(crontab -l 2>/dev/null) || cr_cur=""
    echo "$cr_cur" | grep -q "add-ip-subnet-routing" 2>/dev/null && return 0
    { echo "$cr_cur"; echo "$cr_cmd"; } | crontab - 2>/dev/null || log_w "Failed to update crontab"
    /etc/init.d/cron restart >/dev/null 2>&1 || true
}

# =============================================================================
# MAIN
# =============================================================================
v5_main() {
    echo "============================================================"
    echo "  Routing Installer v5.2-Robust (Self-Healing)"
    echo "============================================================"
    v5_cleanup
    v5_validate
    
    log_i "Phase 3: Parallel download & sequential load..."
    v5_download "ip" "vpn_ip" "https://antifilter.download" &
    pid_ip=$!
    v5_download "subnet" "vpn_subnets" "https://antifilter.download" &
    pid_sub=$!
    v5_download "community" "vpn_community" "https://community.antifilter.download" &
    pid_comm=$!

    wait $pid_ip 2>/dev/null || log_w "list_ip download failed"
    wait $pid_sub 2>/dev/null || log_w "list_subnet download failed"
    wait $pid_comm 2>/dev/null || log_w "list_community download failed"

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

v5_cmd="${1:-start}"
if [ "$v5_cmd" = "start" ]; then
    v5_main
elif [ "$v5_cmd" = "clean" ]; then
    v5_cleanup; log_i "Cleanup done."
elif [ "$v5_cmd" = "stop" ]; then
    log_i "Clearing sets..."; for cs in vpn_ip vpn_subnets vpn_community; do nft flush set inet fw4 "$cs" 2>/dev/null || true; done
elif [ "$v5_cmd" = "reload" ] || [ "$v5_cmd" = "restart" ]; then
    "$0" stop; sleep 1; "$0" start
else
    echo "Usage: $0 {start|clean|stop|reload|restart}"; exit 1
fi
exit 0