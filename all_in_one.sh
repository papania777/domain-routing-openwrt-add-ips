#!/bin/sh /etc/rc.common
# =============================================================================
# v8.10-init-stable.sh
# Unified Routing: Domain + IP/Subnet/Community + Sing-Box Extended
# Исправлено: Точная структура /etc/rc.common, интеграция install.sh, логирование
# =============================================================================

START=99
STOP=95

# 🔧 ВНИМАНИЕ: Замените URL на прямую ссылку к вашему raw-файлу на GitHub!
V8_SCRIPT_URL="https://raw.githubusercontent.com/papania777/domain-routing-openwrt-add-ips/main/add_IPs.sh"

v8_green='\033[32;1m'; v8_red='\033[31;1m'; v8_yellow='\033[33;1m'; v8_nc='\033[0m'
v8_log() { logger -t "v8-boot" "$1"; printf "${v8_green}[INFO]${v8_nc} %s\n" "$1"; }
v8_log_w() { logger -t "v8-boot" "[WARN] $1"; printf "${v8_yellow}[WARN]${v8_nc} %s\n" "$1"; }
v8_log_e() { logger -t "v8-boot" "[ERROR] $1"; printf "${v8_red}[ERROR]${v8_nc} %s\n" "$1"; }

# =============================================================================
# INTEGRATED: sing-box-extended install logic (from install.sh)
# =============================================================================
v8_install_sb_extended() {
    v8_log "Updating sing-box-extended..."
    API_URL="https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest"
    DEST_FILE="/usr/bin/sing-box"
    
    if command -v curl >/dev/null 2>&1; then
        FETCH="curl -fsSL --insecure"; DOWNLOAD="curl -fsSL --insecure -o"
    elif command -v wget >/dev/null 2>&1; then
        FETCH="wget -qO- --no-check-certificate"; DOWNLOAD="wget -q --no-check-certificate -O"
    else
        v8_log_e "curl/wget missing"; return 1
    fi

    SERVICE_NAME="sing-box"
    [ -f "/etc/init.d/podkop" ] && SERVICE_NAME="podkop"

    HOST_ARCH=$(uname -m)
    [ -f "/etc/openwrt_release" ] && DISTRIB_ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH") && \
        case "$DISTRIB_ARCH" in *mipsel*|*mipsle*) HOST_ARCH="mipsel" ;; *mips64el*|*mips64le*) HOST_ARCH="mips64el" ;; esac
    
    case $HOST_ARCH in
        aarch64) ARCH="arm64" ;; armv7*) ARCH="armv7" ;; armv6*) ARCH="armv6" ;;
        x86_64) ARCH="amd64" ;; i386|i686) ARCH="386" ;; mips) ARCH="mips-softfloat" ;;
        mipsel|mipsle) ARCH="mipsle-softfloat" ;; mips64) ARCH="mips64" ;;
        mips64el|mips64le) ARCH="mips64le" ;; riscv64) ARCH="riscv64" ;; s390x) ARCH="s390x" ;; *) return 1 ;;
    esac

    API_RESPONSE=$($FETCH "$API_URL" 2>/dev/null) || true
    [ -z "$API_RESPONSE" ] && { v8_log_w "GitHub API unreachable."; return 0; }

    DOWNLOAD_URL=$(echo "$API_RESPONSE" | tr ',' '\n' | grep "browser_download_url" | grep "linux-$ARCH.tar.gz" | head -n 1 | awk -F '"' '{print $4}')
    [ -z "$DOWNLOAD_URL" ] && { v8_log_w "No binary for $ARCH."; return 0; }

    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    WORK_DIR="/tmp/sb-ext-install"
    rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"; cd "$WORK_DIR"

    $DOWNLOAD "sb.tar.gz" "$DOWNLOAD_URL" 2>/dev/null || { cd /; rm -rf "$WORK_DIR"; v8_log_w "Download failed."; return 0; }
    [ -s "sb.tar.gz" ] || { cd /; rm -rf "$WORK_DIR"; return 0; }

    service "$SERVICE_NAME" stop 2>/dev/null || true
    sleep 2
    tar -xzf "sb.tar.gz" 2>/dev/null
    BINARY_PATH=$(find . -type f -name sing-box | head -n 1)
    if [ -n "$BINARY_PATH" ]; then
        mv -f "$BINARY_PATH" "$DEST_FILE" 2>/dev/null
        chmod +x "$DEST_FILE"
        v8_log "✅ sing-box-extended binary replaced."
    fi
    cd /; rm -rf "$WORK_DIR"
    return 0
}

# =============================================================================
# CORE FUNCTIONS
# =============================================================================
v8_cleanup() {
    [ -f /etc/sing-box/config.json ] && cp /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)" 2>/dev/null
    crontab -l 2>/dev/null | grep -v -e "add-ip-subnet-routing" -e "getdomains" -e "v8-unified" | crontab - 2>/dev/null || true
    for v8_r in $(uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_|\.set='vpn_domains'" | cut -d= -f1 | cut -d. -f2); do
        uci delete firewall."$v8_r" >/dev/null 2>&1
    done
    uci commit firewall >/dev/null 2>&1
    rm -f /usr/sbin/v8-mark-rules.sh
    rm -rf /tmp/lst/* /tmp/dnsmasq.d/* /tmp/v8_batch.nft /tmp/sb-*
    v8_log "Cleanup done."
}

v8_create_sets() {
    for s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        nft list set inet fw4 "$s" >/dev/null 2>&1 || \
            nft add set inet fw4 "$s" '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
    done
}

v8_validate() {
    command -v curl >/dev/null 2>&1 || { v8_log_e "curl missing"; return 1; }
    command -v nft  >/dev/null 2>&1 || { v8_log_e "nft missing"; return 1; }
    sed -i '/^[[:space:]]*99[[:space:]]*vpn/d' /etc/iproute2/rt_tables 2>/dev/null || true
    echo '99 vpn' >> /etc/iproute2/rt_tables
    uci show network 2>/dev/null | grep -q "mark='0x1'" || {
        uci add network rule >/dev/null 2>&1
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit network
    }
    v8_log "Network rules validated."
}

v8_cleanup_dns() {
    v8_cleaned=0
    command -v dnscrypt-proxy >/dev/null 2>&1 && { /etc/init.d/dnscrypt-proxy stop 2>/dev/null || true; /etc/init.d/dnscrypt-proxy disable 2>/dev/null || true; v8_cleaned=1; }
    command -v stubby >/dev/null 2>&1 && { /etc/init.d/stubby stop 2>/dev/null || true; /etc/init.d/stubby disable 2>/dev/null || true; v8_cleaned=1; }
    if [ "$v8_cleaned" -eq 1 ] || uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null | grep -q "1"; then
        uci del dhcp.@dnsmasq[0].noresolv 2>/dev/null || true
        uci del dhcp.@dnsmasq[0].server 2>/dev/null || true
        uci commit dhcp 2>/dev/null || true
        /etc/init.d/dnsmasq restart 2>/dev/null || true
        v8_log "Default DNS restored."
    fi
}

v8_setup_domains() {
    opkg list-installed | grep -q dnsmasq-full || {
        opkg update >/dev/null 2>&1; cd /tmp && opkg download dnsmasq-full 2>/dev/null
        opkg remove dnsmasq 2>/dev/null && opkg install dnsmasq-full --cache /tmp 2>/dev/null
        [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
    }
    uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d' 2>/dev/null; uci commit dhcp 2>/dev/null
    mkdir -p /tmp/dnsmasq.d

    DOM_FILE="/tmp/dnsmasq.d/domains.lst"
    curl -f -s --max-time 120 -o "$DOM_FILE" "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst" 2>/dev/null || return 1
    [ -s "$DOM_FILE" ] || return 1
    if dnsmasq --conf-file="$DOM_FILE" --test 2>&1 | grep -q "syntax check OK"; then
        /etc/init.d/dnsmasq stop 2>/dev/null; /etc/init.d/dnsmasq start 2>/dev/null
        sleep 2
        grep -oE 'nftset=/[^/]+/' "$DOM_FILE" 2>/dev/null | head -3 | sed 's|nftset=/||; s|/||' | while read d; do [ -n "$d" ] && nslookup "$d" 127.0.0.1 >/dev/null 2>&1 & done; wait
        v8_log "Domains configured."
    else
        v8_log_w "Domain syntax check failed."
    fi
}

v8_setup_fw() {
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/30-vpnroute << 'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "tun0" ] && { logger -t "v8-boot" "tun0 up, adding route"; sleep 10; ip route add table vpn default dev tun0 2>/dev/null || true; }
EOF
    chmod +x /etc/hotplug.d/iface/30-vpnroute
    cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute 2>/dev/null || true

    uci show firewall | grep -q "@zone.*name='singbox'" || {
        uci add firewall zone; uci set firewall.@zone[-1].name='singbox'; uci set firewall.@zone[-1].device='tun0'
        uci set firewall.@zone[-1].forward='ACCEPT'; uci set firewall.@zone[-1].output='ACCEPT'; uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].masq='1'; uci set firewall.@zone[-1].mtu_fix='1'; uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    }
    uci show firewall | grep -q "@forwarding.*name='singbox-lan'" || {
        uci add firewall forwarding; uci set firewall.@forwarding[-1].name='singbox-lan'
        uci set firewall.@forwarding[-1].dest='singbox'; uci set firewall.@forwarding[-1].src='lan'; uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    }
}

v8_setup_singbox() {
    opkg list-installed | grep -q sing-box || { opkg update >/dev/null 2>&1; opkg install sing-box >/dev/null 2>&1; }
    v8_install_sb_extended
    
    if [ -f "/etc/config/sing-box" ]; then
        sed -i "s/option user 'sing-box'/option user 'root'/" /etc/config/sing-box 2>/dev/null || true
        uci set sing-box.@sing-box[0].enabled='1' 2>/dev/null || true
        uci del sing-box.@sing-box[0].nofilelimit 2>/dev/null || true
        uci del sing-box.@sing-box[0].norlimit 2>/dev/null || true
        uci commit sing-box 2>/dev/null || true
    fi
    
    SVC="sing-box"; [ -f "/etc/init.d/podkop" ] && SVC="podkop"
    [ ! -f /etc/sing-box/config.json ] && { mkdir -p /etc/sing-box; printf '{"log":{"level":"debug"},"inbounds":[{"type":"tun","interface_name":"tun0","domain_strategy":"ipv4_only","address":["172.16.250.1/30"],"auto_route":false,"strict_route":false,"sniff":true}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"auto_detect_interface":true}}\n' > /etc/sing-box/config.json; }
    sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 || true
    
    /etc/init.d/$SVC stop 2>/dev/null || true; sleep 1; /etc/init.d/$SVC start 2>/dev/null || true
    if ! ps | grep -v grep | grep -q "sing-box.*run"; then
        killall sing-box 2>/dev/null || true; sleep 1
        nohup /usr/bin/sing-box run -c /etc/sing-box/config.json >/tmp/sb-stdout.log 2>/tmp/sb-stderr.log &
    fi
    
    w=0; while [ $w -lt 40 ]; do ip link show tun0 >/dev/null 2>&1 && { v8_log "✅ tun0 ready."; return 0; }; sleep 1; w=$((w+1)); done
    v8_log_w "tun0 not created after 40s. Check /etc/sing-box/config.json"
}

v8_load_all() {
    v8_log "Loading IP lists..."
    for pair in "ip:vpn_ip:https://antifilter.download" "subnet:vpn_subnets:https://antifilter.download" "community:vpn_community:https://community.antifilter.download"; do
        ln="${pair%%:*}"; rest="${pair#*:}"; ls="${rest%%:*}"; lb="${rest#*:}"
        lt="/tmp/lst/${ls}.lst"; mkdir -p /tmp/lst
        curl -f -s --max-time 120 -o "$lt" "${lb}/list/${ln}.lst" 2>/dev/null || continue
        [ -s "$lt" ] || continue
        nft flush set inet fw4 "$ls" 2>/dev/null || true
        sed 's/\r//g' "$lt" | grep -oE '[0-9.]+(/[0-9]{1,2})?' | sort -u > /tmp/lst/${ls}.valid 2>/dev/null || true
        [ -s /tmp/lst/${ls}.valid ] || continue
        cnt=0; b=""; done=0
        while IFS= read -r l; do
            [ -z "$l" ] && continue; [ -z "$b" ] && b="$l" || b="${b}, ${l}"
            cnt=$((cnt+1))
            if [ "$cnt" -ge 500 ]; then
                printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/v8_batch.nft
                nft -f /tmp/v8_batch.nft 2>/dev/null && done=$((done+cnt)); b=""; cnt=0
            fi
        done < /tmp/lst/${ls}.valid
        [ -n "$b" ] && printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/v8_batch.nft && nft -f /tmp/v8_batch.nft 2>/dev/null && done=$((done+cnt))
        rm -f "$lt" /tmp/lst/${ls}.valid /tmp/v8_batch.nft
    done
    v8_log "IP lists loaded."
}

v8_apply_rules() {
    hp="/usr/sbin/v8-mark-rules.sh"
    cat > "$hp" << 'HELPER'
#!/bin/sh
[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0
for c in prerouting output; do
    for s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        nft list chain inet fw4 "$c" 2>/dev/null | grep -q "v8_${s}_${c}" || \
            nft add rule inet fw4 "$c" ip daddr "@$s" meta mark set 0x1 comment "v8_${s}_${c}" 2>/dev/null || true
    done
done
HELPER
    chmod +x "$hp"
    uci show firewall 2>/dev/null | grep -q "v8-mark-rules" || {
        uci add firewall include >/dev/null 2>&1; uci set firewall.@include[-1].type='script'
        uci set firewall.@include[-1].path="$hp"; uci set firewall.@include[-1].reload='1'; uci commit firewall >/dev/null 2>&1
    }
    
    v8_log "Waiting for sets..."; w=0
    while [ $w -lt 60 ]; do
        ip=$(nft list set inet fw4 vpn_ip 2>/dev/null | grep -cE "^\s+[0-9]" || echo 0)
        [ "$ip" -gt 1000 ] && break; sleep 1; w=$((w+1))
    done
    
    /etc/init.d/firewall reload >/dev/null 2>&1 || true; sleep 2
    "$hp"
    v8_log "Marking rules persistent via UCI."
}

v8_setup_route() {
    if ip link show tun0 >/dev/null 2>&1; then
        ip route del table vpn default 2>/dev/null || true
        ip route add table vpn default dev tun0 2>/dev/null && v8_log "Route added: default dev tun0 table vpn"
    fi
    if ! uci show network 2>/dev/null | grep -q "vpn_route_default"; then
        uci set network.vpn_route_default=route >/dev/null 2>&1; uci set network.vpn_route_default.name='vpn-default' >/dev/null 2>&1
        uci set network.vpn_route_default.interface='tun0' >/dev/null 2>&1; uci set network.vpn_route_default.table='vpn' >/dev/null 2>&1
        uci set network.vpn_route_default.target='0.0.0.0/0' >/dev/null 2>&1; uci commit network >/dev/null 2>&1
    fi
}

v8_setup_cron() {
    /etc/init.d/cron enable 2>/dev/null || true
    if ! crontab -l 2>/dev/null | grep -q "v8-unified-routing start"; then
        (crontab -l 2>/dev/null || true; echo "0 */12 * * * /etc/init.d/v8-unified-routing start") | crontab - 2>/dev/null
        /etc/init.d/cron restart 2>/dev/null || true
        v8_log "✅ Cron configured."
    fi
}

# =============================================================================
# MAIN ENTRY
# =============================================================================
v8_main() {
    v8_log "=== Script start ==="
    v8_cleanup
    v8_create_sets
    v8_validate
    v8_cleanup_dns
    v8_setup_domains
    v8_setup_fw
    v8_setup_singbox
    v8_load_all
    v8_apply_rules
    v8_setup_route
    v8_setup_cron
    v8_log "=== Script end ==="
}

# =============================================================================
# OPENWRT INIT INTERFACE
# =============================================================================
start() { v8_main; }
stop() { v8_log "Stopping..."; for s in vpn_domains vpn_ip vpn_subnets vpn_community; do nft flush set inet fw4 "$s" 2>/dev/null || true; done; }
restart() { stop; sleep 2; start; }