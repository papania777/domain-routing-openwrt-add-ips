#!/bin/sh
# add-ip-subnet-routing-v4.7-stream-minimal.sh
# 100% compatible with: sh <(wget -O - URL) on OpenWrt ash
# NO local, NO heredoc, NO complex one-liners

GREEN='\033[32;1m'
RED='\033[31;1m'
YELLOW='\033[33;1m'
NC='\033[0m'

log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

check_prereqs() {
    log_info "Checking prerequisites..."
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl missing"
        exit 1
    fi
    if ! command -v nft >/dev/null 2>&1; then
        log_error "nft missing"
        exit 1
    fi
    if ! nft list table inet fw4 >/dev/null 2>&1; then
        log_error "Table inet fw4 not found"
        exit 1
    fi
    if ! grep -q "99 vpn" /etc/iproute2/rt_tables 2>/dev/null; then
        log_info "Adding '99 vpn' to rt_tables"
        echo '99 vpn' >> /etc/iproute2/rt_tables
    fi
    log_info "Prerequisites OK."
}

create_sets() {
    log_info "Preparing nft sets..."
    for s in vpn_ip vpn_subnets vpn_community; do
        if ! nft list set inet fw4 "$s" >/dev/null 2>&1; then
            if ! nft add set inet fw4 "$s" '{ type ipv4_addr; flags interval; }' 2>/dev/null; then
                log_error "Failed to create set $s"
                exit 1
            fi
        fi
    done
}

cleanup_legacy_uci() {
    log_info "Checking for legacy ipset UCI rules..."
    legacy_rules=""
    legacy_rules=$(uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_" | cut -d= -f1 | cut -d. -f2)
    if [ -z "$legacy_rules" ]; then
        return 0
    fi
    for r in $legacy_rules; do
        log_info "Deleting legacy rule: $r"
        uci delete firewall."$r" >/dev/null 2>&1
    done
    uci commit firewall >/dev/null 2>&1
}

load_list_fast() {
    # Arguments: $1=list_name, $2=set_name, $3=url_base
    load_list_name="$1"
    load_set_name="$2"
    load_url_base="${3:-https://antifilter.download}"
    load_url="${load_url_base}/list/${load_list_name}.lst"
    load_tmp="/tmp/lst/${load_list_name}.lst"
    load_valid="/tmp/lst/${load_list_name}.valid"
    load_batch="/tmp/lst/batch.nft"
    mkdir -p /tmp/lst

    log_info "Downloading ${load_list_name}.lst..."
    if ! curl -f -s --max-time 120 -o "$load_tmp" "$load_url" 2>/dev/null; then
        log_error "Download failed"
        return 1
    fi
    if [ ! -s "$load_tmp" ]; then
        log_error "File empty"
        return 1
    fi

    log_info "Flushing set ${load_set_name}..."
    nft flush set inet fw4 "${load_set_name}" 2>/dev/null || true

    log_info "Pre-filtering valid IPs..."
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$' "$load_tmp" > "$load_valid" 2>/dev/null || true

    if [ ! -s "$load_valid" ]; then
        log_warn "No valid entries"
        rm -f "$load_tmp" "$load_valid" "$load_batch"
        return 1
    fi

    log_info "Loading entries (batch: 100)..."
    load_count=0
    load_batch_data=""
    load_loaded=0

    while IFS= read -r load_line; do
        if [ -z "$load_line" ]; then
            continue
        fi
        if [ -z "$load_batch_data" ]; then
            load_batch_data="$load_line"
        else
            load_batch_data="${load_batch_data}, ${load_line}"
        fi
        load_count=$((load_count + 1))
        if [ "$load_count" -ge 100 ]; then
            printf 'add element inet fw4 %s { %s }\n' "${load_set_name}" "${load_batch_data}" > "${load_batch}"
            if nft -f "${load_batch}" 2>/dev/null; then
                load_loaded=$((load_loaded + load_count))
            fi
            load_batch_data=""
            load_count=0
        fi
    done < "$load_valid"

    if [ -n "$load_batch_data" ]; then
        printf 'add element inet fw4 %s { %s }\n' "${load_set_name}" "${load_batch_data}" > "${load_batch}"
        if nft -f "${load_batch}" 2>/dev/null; then
            load_loaded=$((load_loaded + load_count))
        fi
    fi

    rm -f "$load_tmp" "$load_valid" "$load_batch"
    log_info "Loaded ~${load_loaded} entries into ${load_set_name}."
    return 0
}

apply_mark_rules() {
    log_info "Applying nft marking rules..."
    # Create helper via printf (NO heredoc)
    printf '%s\n' '#!/bin/sh' \
        '[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0' \
        'add_if_missing() {' \
        '    if ! nft list chain inet fw4 "$1" 2>/dev/null | grep -q "$2"; then' \
        '        nft add rule inet fw4 "$1" ip daddr "$3" meta mark set 0x1 comment "$2" 2>/dev/null || true' \
        '    fi' \
        '}' \
        'for amr_chain in prerouting output; do' \
        '    add_if_missing "$amr_chain" "mark_vpn_domains_${amr_chain}" "@vpn_domains"' \
        '    add_if_missing "$amr_chain" "mark_vpn_ip_${amr_chain}"       "@vpn_ip"' \
        '    add_if_missing "$amr_chain" "mark_vpn_sub_${amr_chain}"      "@vpn_subnets"' \
        '    add_if_missing "$amr_chain" "mark_vpn_comm_${amr_chain}"     "@vpn_community"' \
        'done' > /usr/sbin/apply-vpn-mark-rules.sh
    chmod +x /usr/sbin/apply-vpn-mark-rules.sh

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

setup_cron() {
    cron_cmd="0 */12 * * * /etc/init.d/add-ip-subnet-routing start"
    cron_cur=""
    cron_cur=$(crontab -l 2>/dev/null) || cron_cur=""
    if echo "$cron_cur" | grep -q "add-ip-subnet-routing" 2>/dev/null; then
        return 0
    fi
    if ! { echo "$cron_cur"; echo "$cron_cmd"; } | crontab - 2>/dev/null; then
        log_warn "Crontab update failed"
    fi
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    log_info "Cron configured (every 12h)."
}

main_entry() {
    echo "============================================================"
    echo "  Add IP/Subnet/Community Routing v4.7 (Stream-Minimal)"
    echo "============================================================"
    check_prereqs || exit 1
    cleanup_legacy_uci
    create_sets
    load_list_fast "ip" "vpn_ip" "https://antifilter.download" || log_warn "list_ip failed"
    load_list_fast "subnet" "vpn_subnets" "https://antifilter.download" || log_warn "list_subnet failed"
    load_list_fast "community" "vpn_community" "https://community.antifilter.download" || log_warn "list_community failed"
    apply_mark_rules
    setup_cron
    log_info "Reloading firewall..."
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    echo "============================================================"
    log_info "DONE."
    echo "============================================================"
}

# Main dispatcher (flat case, no nested structures)
cmd_action="${1:-start}"
if [ "$cmd_action" = "start" ]; then
    main_entry
elif [ "$cmd_action" = "stop" ]; then
    log_info "Clearing sets..."
    for clr_s in vpn_ip vpn_subnets vpn_community; do
        nft flush set inet fw4 "$clr_s" 2>/dev/null || true
    done
elif [ "$cmd_action" = "reload" ] || [ "$cmd_action" = "restart" ]; then
    "$0" stop
    sleep 1
    "$0" start
else
    echo "Usage: $0 {start|stop|reload|restart}"
    exit 1
fi
exit 0