#!/bin/sh
GREEN='\033[32;1m'
RED='\033[31;1m'
YELLOW='\033[33;1m'
NC='\033[0m'

log_info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

check_prereqs() {
    log_info "Checking prerequisites..."
    if ! command -v curl >/dev/null 2>&1; then log_error "curl missing"; exit 1; fi
    if ! command -v nft  >/dev/null 2>&1; then log_error "nft missing"; exit 1; fi
    if ! nft list table inet fw4 >/dev/null 2>&1; then log_error "Table inet fw4 not found"; exit 1; fi
    if ! grep -q "99 vpn" /etc/iproute2/rt_tables 2>/dev/null; then
        log_info "Adding '99 vpn' to rt_tables"
        echo '99 vpn' >> /etc/iproute2/rt_tables
    fi
    log_info "Prerequisites OK."
}

create_sets() {
    log_info "Preparing nft sets..."
    for set in vpn_ip vpn_subnets vpn_community; do
        if ! nft list set inet fw4 "$set" >/dev/null 2>&1; then
            if ! nft add set inet fw4 "$set" '{ type ipv4_addr; flags interval; }' 2>/dev/null; then
                log_error "Failed to create set '$set'"
                exit 1
            fi
        fi
    done
}

cleanup_legacy_uci() {
    log_info "Checking for legacy 'ipset' UCI rules..."
    rules=$(uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_" | cut -d= -f1 | cut -d. -f2)
    if [ -z "$rules" ]; then return 0; fi
    for rule in $rules; do
        log_info "Deleting legacy rule: $rule"
        uci delete firewall."$rule" >/dev/null 2>&1
    done
    uci commit firewall >/dev/null 2>&1
}

load_list_fast() {
    local list_name="$1" set_name="$2" url_base="${3:-https://antifilter.download}"
    local url="${url_base}/list/${list_name}.lst"
    local tmp="/tmp/lst/${list_name}.lst"
    local valid="/tmp/lst/${list_name}.valid"
    local batch_file="/tmp/lst/batch.nft"
    mkdir -p /tmp/lst

    log_info "Downloading ${list_name}.lst..."
    if ! curl -f -s --max-time 120 -o "$tmp" "$url" 2>/dev/null; then
        log_error "Download failed"; return 1
    fi
    if [ ! -s "$tmp" ]; then
        log_error "File empty"; return 1
    fi

    log_info "Flushing set '$set_name'..."
    nft flush set inet fw4 "$set_name" 2>/dev/null || true

    log_info "Pre-filtering valid IPs..."
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,2})?$' "$tmp" > "$valid" 2>/dev/null || true

    if [ ! -s "$valid" ]; then
        log_warn "No valid entries in ${list_name}.lst"
        rm -f "$tmp" "$valid" "$batch_file"
        return 1
    fi

    log_info "Loading entries (batch: 100)..."
    local count=0 batch="" loaded=0 line

    while IFS= read -r line; do
        if [ -z "$line" ]; then continue; fi
        if [ -z "$batch" ]; then
            batch="$line"
        else
            batch="${batch}, ${line}"
        fi
        count=$((count + 1))
        if [ "$count" -ge 100 ]; then
            printf 'add element inet fw4 %s { %s }\n' "$set_name" "$batch" > "$batch_file"
            if nft -f "$batch_file" 2>/dev/null; then
                loaded=$((loaded + count))
            fi
            batch=""
            count=0
        fi
    done < "$valid"

    if [ -n "$batch" ]; then
        printf 'add element inet fw4 %s { %s }\n' "$set_name" "$batch" > "$batch_file"
        if nft -f "$batch_file" 2>/dev/null; then
            loaded=$((loaded + count))
        fi
    fi

    rm -f "$tmp" "$valid" "$batch_file"
    log_info "Loaded ~$loaded entries into '$set_name'."
    return 0
}

apply_mark_rules() {
    log_info "Applying nft marking rules..."
    cat > /usr/sbin/apply-vpn-mark-rules.sh << 'HELPER'
#!/bin/sh
[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0
add_if_missing() {
    if ! nft list chain inet fw4 "$1" 2>/dev/null | grep -q "$2"; then
        nft add rule inet fw4 "$1" ip daddr "$3" meta mark set 0x1 comment "$2" 2>/dev/null || true
    fi
}
for chain in prerouting output; do
    add_if_missing "$chain" "mark_vpn_domains_${chain}" "@vpn_domains"
    add_if_missing "$chain" "mark_vpn_ip_${chain}"       "@vpn_ip"
    add_if_missing "$chain" "mark_vpn_sub_${chain}"      "@vpn_subnets"
    add_if_missing "$chain" "mark_vpn_comm_${chain}"     "@vpn_community"
done
HELPER
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
    local cmd="0 */12 * * * /etc/init.d/add-ip-subnet-routing start"
    local cur
    cur=$(crontab -l 2>/dev/null) || cur=""
    if echo "$cur" | grep -q "add-ip-subnet-routing" 2>/dev/null; then
        return 0
    fi
    if ! { echo "$cur"; echo "$cmd"; } | crontab - 2>/dev/null; then
        log_warn "Crontab update failed"
    fi
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    log_info "Cron configured (every 12h)."
}

main() {
    echo "============================================================"
    echo "  Add IP/Subnet/Community Routing v4.5 (Strict ash)"
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

case "${1:-start}" in
    start)
        main
        ;;
    stop)
        log_info "Clearing..."
        for s in vpn_ip vpn_subnets vpn_community; do
            nft flush set inet fw4 "$s" 2>/dev/null || true
        done
        ;;
    reload|restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;
    *)
        echo "Usage: $0 {start|stop|reload|restart}"
        exit 1
        ;;
esac
exit 0