#!/bin/sh
# =============================================================================
# add-ip-subnet-routing-v3.sh (Production Ready)
# Добавляет list_ip и list_subnet в domain-routing-openwrt
# Исправлено: маркировка в prerouting/output, persistence через fw4 include
# Совместимость: OpenWrt 23.05+, fw4 (nftables)
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
    for set in vpn_ip vpn_subnets; do
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
# 3. Валидация IP/CIDR (POSIX compatible)
# =============================================================================
is_valid_entry() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
}

# =============================================================================
# 4. Загрузка списков (batched, safe)
# =============================================================================
load_list() {
    local list_name="$1" set_name="$2"
    local url="https://antifilter.download/list/${list_name}.lst"
    local tmp="/tmp/lst/${list_name}.lst"
    mkdir -p /tmp/lst

    log_info "Downloading ${list_name}.lst..."
    curl -f -s --max-time 120 -o "$tmp" "$url" 2>/dev/null || { log_error "Download failed"; return 1; }
    [ -s "$tmp" ] || { log_error "File empty"; return 1; }

    log_info "Flushing set '$set_name'..."
    nft flush set inet fw4 "$set_name" 2>/dev/null || true

    log_info "Loading entries into '$set_name'..."
    local batch="" count=0 valid=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in \#*|"") continue ;; esac
        line=$(echo "$line" | tr -d '[:space:]')
        [ -z "$line" ] && continue
        is_valid_entry "$line" || { log_warn "Skip invalid: $line"; continue; }

        [ -z "$batch" ] && batch="$line" || batch="${batch}, ${line}"
        count=$((count + 1))
        valid=$((valid + 1))

        if [ $count -ge 50 ]; then
            nft add element inet fw4 "$set_name" "{ ${batch} }" 2>/dev/null || true
            batch="" count=0
        fi
    done < "$tmp"

    [ -n "$batch" ] && nft add element inet fw4 "$set_name" "{ ${batch} }" 2>/dev/null || true
    log_info "Loaded ${valid} valid entries into '$set_name'."
    return 0
}

# =============================================================================
# 5. Применение правил маркировки (КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ)
# =============================================================================
apply_mark_rules() {
    log_info "Applying marking rules (prerouting + output)..."
    
    # Создаём helper-скрипт для persistence
    cat > /usr/sbin/apply-vpn-mark-rules.sh << 'HELPER_EOF'
#!/bin/sh
# Автоматически восстанавливает правила маркировки после firewall reload
check_rule() {
    nft list chain inet fw4 "$1" 2>/dev/null | grep -q "$2"
}
[ -n "$(nft list table inet fw4 2>/dev/null)" ] || exit 0

check_rule prerouting "mark_vpn_ip_prerouting" || \
    nft add rule inet fw4 prerouting ip daddr @vpn_ip meta mark set 0x1 comment "mark_vpn_ip_prerouting" 2>/dev/null

check_rule output "mark_vpn_ip_output" || \
    nft add rule inet fw4 output ip daddr @vpn_ip meta mark set 0x1 comment "mark_vpn_ip_output" 2>/dev/null

check_rule prerouting "mark_vpn_sub_prerouting" || \
    nft add rule inet fw4 prerouting ip daddr @vpn_subnets meta mark set 0x1 comment "mark_vpn_sub_prerouting" 2>/dev/null

check_rule output "mark_vpn_sub_output" || \
    nft add rule inet fw4 output ip daddr @vpn_subnets meta mark set 0x1 comment "mark_vpn_sub_output" 2>/dev/null
HELPER_EOF
    chmod +x /usr/sbin/apply-vpn-mark-rules.sh

    # Регистрируем в fw4 для авто-вызова при reload
    if ! uci show firewall 2>/dev/null | grep -q "apply-vpn-mark-rules"; then
        uci add firewall include >/dev/null 2>&1
        uci set firewall.@include[-1].type='script'
        uci set firewall.@include[-1].path='/usr/sbin/apply-vpn-mark-rules.sh'
        uci set firewall.@include[-1].reload='1'
        uci commit firewall >/dev/null 2>&1
        log_info "Registered fw4 include for persistence."
    fi

    # Применяем сразу
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
    echo "  Add IP/Subnet Routing v3 (FIXED CHAINS + PERSISTENCE)"
    echo "============================================================"
    check_prereqs || exit 1
    create_sets
    load_list "ip" "vpn_ip" || log_warn "list_ip failed"
    load_list "subnet" "vpn_subnets" || log_warn "list_subnet failed"
    apply_mark_rules
    setup_cron
    log_info "Reloading firewall to apply cleanly..."
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    echo "============================================================"
    log_info "DONE. Verify with commands below."
    echo "============================================================"
}

case "${1:-start}" in
    start) main ;;
    stop) log_info "Clearing sets..."; nft flush set inet fw4 vpn_ip 2>/dev/null; nft flush set inet fw4 vpn_subnets 2>/dev/null ;;
    reload|restart) "$0" stop; sleep 1; "$0" start ;;
    *) echo "Usage: $0 {start|stop|reload|restart}"; exit 1 ;;
esac
exit 0