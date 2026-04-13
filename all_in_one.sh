#!/bin/sh
# =============================================================================
# v9.0-production.sh
# Unified Routing: Domain + IP/Subnet/Community + Sing-Box Extended
# PRODUCTION: Auto-installs to /etc/init.d/ when run via sh <(wget...)
# POSIX-compatible, no interactive prompts, full logging to logread
# =============================================================================

V8_SCRIPT_URL="https://raw.githubusercontent.com/papania777/domain-routing-openwrt-add-ips/refs/heads/main/all_in_one.sh"

# Colors for terminal output
v8_g='\033[32;1m'; v8_r='\033[31;1m'; v8_y='\033[33;1m'; v8_n='\033[0m'
v8_log() { logger -t "v8-boot" "$1"; printf "${v8_g}[INFO]${v8_n} %s\n" "$1"; }
v8_log_w() { logger -t "v8-boot" "[WARN] $1"; printf "${v8_y}[WARN]${v8_n} %s\n" "$1"; }
v8_log_e() { logger -t "v8-boot" "[ERROR] $1"; printf "${v8_r}[ERROR]${v8_n} %s\n" "$1"; }

# =============================================================================
# AUTO-INSTALL: Detects sh <(wget...) and installs to /etc/init.d/
# =============================================================================
v8_auto_install() {
    v8_init="/etc/init.d/v8-unified-routing"
    
    # If already installed and executable, skip
    [ -x "$v8_init" ] && { v8_log "Already installed at $v8_init"; return 0; }
    
    v8_tmp="/tmp/v8-install-tmp.sh"
    
    # Try to download ourselves
    if wget -q -O "$v8_tmp" "$V8_SCRIPT_URL" 2>/dev/null || curl -fsSL -o "$v8_tmp" "$V8_SCRIPT_URL" 2>/dev/null; then
        # Remove Windows line endings if present
        sed -i 's/\r$//' "$v8_tmp" 2>/dev/null
        
        # Verify it's a valid script
        if head -n 1 "$v8_tmp" | grep -q '#!/bin/sh'; then
            # Install to init.d
            cp "$v8_tmp" "$v8_init"
            chmod +x "$v8_init"
            rm -f "$v8_tmp"
            
            # Enable for auto-start (creates symlinks in /etc/rc.d/)
            "$v8_init" enable 2>/dev/null || true
            
            # Setup cron for auto-update
            /etc/init.d/cron enable 2>/dev/null || true
            if ! crontab -l 2>/dev/null | grep -q "v8-unified-routing start"; then
                (crontab -l 2>/dev/null || true; echo "0 */12 * * * $v8_init start") | crontab - 2>/dev/null
                /etc/init.d/cron restart 2>/dev/null || true
            fi
            
            v8_log "✅ Auto-installed to $v8_init and enabled for auto-start"
            return 0
        fi
        rm -f "$v8_tmp"
    fi
    v8_log_w "Auto-install failed. Script will run once without persistence."
    return 1
}

# =============================================================================
# SING-BOX EXTENDED INSTALL (from install.sh, POSIX-compatible)
# =============================================================================
v8_install_sb_ext() {
    v8_log "Updating sing-box-extended..."
    API="https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest"
    DEST="/usr/bin/sing-box"
    
    if command -v curl >/dev/null 2>&1; then FETCH="curl -fsSL --insecure"; DL="curl -fsSL --insecure -o"
    elif command -v wget >/dev/null 2>&1; then FETCH="wget -qO- --no-check-certificate"; DL="wget -q --no-check-certificate -O"
    else v8_log_e "curl/wget missing"; return 1; fi

    SVC="sing-box"
    [ -f "/etc/init.d/podkop" ] && SVC="podkop"

    ARCH=$(uname -m)
    [ -f "/etc/openwrt_release" ] && D_ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH") && \
        case "$D_ARCH" in *mipsel*|*mipsle*) ARCH="mipsel";; *mips64el*|*mips64le*) ARCH="mips64el";; esac
    
    case $ARCH in
        aarch64) S="arm64";; armv7*) S="armv7";; armv6*) S="armv6";;
        x86_64) S="amd64";; i386|i686) S="386";; mips) S="mips-softfloat";;
        mipsel|mipsle) S="mipsle-softfloat";; mips64) S="mips64";;
        mips64el|mips64le) S="mips64le";; riscv64) S="riscv64";; s390x) S="s390x";;
        *) v8_log_e "Unsupported arch $ARCH"; return 1;;
    esac

    RESP=$($FETCH "$API" 2>/dev/null) || true
    [ -z "$RESP" ] && { v8_log_w "GitHub API unreachable"; return 0; }

    URL=$(echo "$RESP" | tr ',' '\n' | grep "browser_download_url" | grep "linux-$S.tar.gz" | head -1 | awk -F'"' '{print $4}')
    [ -z "$URL" ] && { v8_log_w "No binary for $ARCH ($S)"; return 0; }

    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    WD="/tmp/sb-ext"; rm -rf "$WD"; mkdir -p "$WD"; cd "$WD"
    
    $DL "sb.tgz" "$URL" 2>/dev/null || { cd /; rm -rf "$WD"; v8_log_w "Download failed"; return 0; }
    [ -s "sb.tgz" ] || { cd /; rm -rf "$WD"; return 0; }

    service "$SVC" stop 2>/dev/null || true; sleep 2
    tar -xzf "sb.tgz" 2>/dev/null
    BIN=$(find . -type f -name sing-box | head -1)
    [ -n "$BIN" ] && { mv -f "$BIN" "$DEST" 2>/dev/null; chmod +x "$DEST"; v8_log "✅ sing-box-extended replaced"; }
    
    cd /; rm -rf "$WD"; service "$SVC" start 2>/dev/null || true
    return 0
}

# =============================================================================
# CORE FUNCTIONS
# =============================================================================
v8_cleanup() {
    [ -f /etc/sing-box/config.json ] && cp /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)" 2>/dev/null
    crontab -l 2>/dev/null | grep -v -e "add-ip-subnet-routing" -e "getdomains" -e "v8-unified" | crontab - 2>/dev/null || true
    for r in $(uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_|\.set='vpn_domains'" | cut -d= -f1 | cut -d. -f2); do
        uci delete firewall."$r" >/dev/null 2>&1
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
    c=0
    command -v dnscrypt-proxy >/dev/null 2>&1 && { /etc/init.d/dnscrypt-proxy stop 2>/dev/null; /etc/init.d/dnscrypt-proxy disable 2>/dev/null; c=1; }
    command -v stubby >/dev/null 2>&1 && { /etc/init.d/stubby stop 2>/dev/null; /etc/init.d/stubby disable 2>/dev/null; c=1; }
    if [ "$c" -eq 1 ] || uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null | grep -q "1"; then
        uci del dhcp.@dnsmasq[0].noresolv 2>/dev/null; uci del dhcp.@dnsmasq[0].server 2>/dev/null
        uci commit dhcp 2>/dev/null; /etc/init.d/dnsmasq restart 2>/dev/null
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

    F="/tmp/dnsmasq.d/domains.lst"
    curl -f -s --max-time 120 -o "$F" "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst" 2>/dev/null || return 1
    [ -s "$F" ] || return 1
    if dnsmasq --conf-file="$F" --test 2>&1 | grep -q "syntax check OK"; then
        /etc/init.d/dnsmasq stop 2>/dev/null; /etc/init.d/dnsmasq start 2>/dev/null
        sleep 2
        grep -oE 'nftset=/[^/]+/' "$F" 2>/dev/null | head -3 | sed 's|nftset=/||; s|/||' | while read d; do [ -n "$d" ] && nslookup "$d" 127.0.0.1 >/dev/null 2>&1 & done; wait
        v8_log "Domains configured."
    else
        v8_log_w "Domain syntax check failed."
    fi
}

v8_setup_fw() {
    mkdir -p /etc/hotplug.d/iface
    printf '%s\n' '#!/bin/sh' '[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "tun0" ] && { logger -t "v8-boot" "tun0 up"; sleep 10; ip route add table vpn default dev tun0 2>/dev/null || true; }' > /etc/hotplug.d/iface/30-vpnroute
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
    v8_install_sb_ext
    
    [ -f "/etc/config/sing-box" ] && {
        sed -i "s/option user 'sing-box'/option user 'root'/" /etc/config/sing-box 2>/dev/null || true
        uci set sing-box.@sing-box[0].enabled='1' 2>/dev/null || true
        uci del sing-box.@sing-box[0].nofilelimit 2>/dev/null || true
        uci del sing-box.@sing-box[0].norlimit 2>/dev/null || true
        uci commit sing-box 2>/dev/null || true
    }
    
    SVC="sing-box"; [ -f "/etc/init.d/podkop" ] && SVC="podkop"
    [ ! -f /etc/sing-box/config.json ] && { mkdir -p /etc/sing-box; printf '{"log":{"level":"debug"},"inbounds":[{"type":"tun","interface_name":"tun0","domain_strategy":"ipv4_only","address":["172.16.250.1/30"],"auto_route":false,"strict_route":false,"sniff":true}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"auto_detect_interface":true}}\n' > /etc/sing-box/config.json; }
    sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 || true
    
    /etc/init.d/$SVC stop 2>/dev/null || true; sleep 1; /etc/init.d/$SVC start 2>/dev/null || true
    if ! ps | grep -v grep | grep -q "sing-box.*run"; then
        killall sing-box 2>/dev/null || true; sleep 1
        nohup /usr/bin/sing-box run -c /etc/sing-box/config.json >/tmp/sb-out.log 2>/tmp/sb-err.log &
    fi
    
    w=0; while [ $w -lt 40 ]; do ip link show tun0 >/dev/null 2>&1 && { v8_log "✅ tun0 ready"; return 0; }; sleep 1; w=$((w+1)); done
    v8_log_w "tun0 not created after 40s"
}

v8_load_all() {
    v8_log "Loading IP lists..."
    for p in "ip:vpn_ip:https://antifilter.download" "subnet:vpn_subnets:https://antifilter.download" "community:vpn_community:https://community.antifilter.download"; do
        ln="${p%%:*}"; r="${p#*:}"; ls="${r%%:*}"; lb="${r#*:}"
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
    printf '%s\n' '#!/bin/sh' '[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0' 'for c in prerouting output; do' 'for s in vpn_domains vpn_ip vpn_subnets vpn_community; do' 'nft list chain inet fw4 "$c" 2>/dev/null | grep -q "v8_${s}_${c}" || nft add rule inet fw4 "$c" ip daddr "@$s" meta mark set 0x1 comment "v8_${s}_${c}" 2>/dev/null || true' 'done' 'done' > "$hp"
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
# MAIN LOGIC
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
# DISPATCHER: Auto-install + dual-mode execution
# =============================================================================

# 1. FIRST: Try to auto-install ourselves if run via sh <(wget...)
v8_auto_install

# 2. Check if called as init script with argument
case "${1:-}" in
    start)
        v8_main
        ;;
    stop)
        v8_log "Stopping..."; for s in vpn_domains vpn_ip vpn_subnets vpn_community; do nft flush set inet fw4 "$s" 2>/dev/null || true; done
        ;;
    restart)
        "$0" stop; sleep 2; "$0" start
        ;;
    enable|disable)
        # Handled by /etc/rc.common symlinks, just log
        logger -t "v8-boot" "Command $1 passed to init system"
        ;;
    *)
        # If no argument (direct execution via sh <(wget...)), run main logic
        v8_main
        ;;
esac

exit 0