#!/bin/sh
# =============================================================================
# v12.1-fixed.sh
# Unified Routing: Domain + IP/Subnet/Community + Sing-Box Extended
# FIXED: Proper if/fi blocks, ash-compatible, no fork-bomb, parallel download
# =============================================================================

V12_URL="https://raw.githubusercontent.com/papania777/domain-routing-openwrt-add-ips/main/all_in_one.sh"
V12_INIT="/etc/init.d/v12-unified-routing"
V12_LOCK="/tmp/v12-routing.lock"

v12_log() { logger -t "v12" "$1"; printf "[INFO] %s\n" "$1"; }
v12_log_w() { logger -t "v12" "[WARN] $1"; printf "[WARN] %s\n" "$1"; }
v12_log_e() { logger -t "v12" "[ERROR] $1"; printf "[ERROR] %s\n" "$1"; }

# =============================================================================
# 1. SAFE BOOTSTRAP
# =============================================================================
if [ "$0" != "$V12_INIT" ]; then
    if [ -x "$V12_INIT" ]; then
        exec "$V12_INIT" start
    fi
    
    v12_log "Downloading v12.1..."
    
    if wget -q -O /tmp/v12-tmp.sh "$V12_URL" 2>/dev/null; then
        :
    elif curl -fsSL -o /tmp/v12-tmp.sh "$V12_URL" 2>/dev/null; then
        :
    else
        v12_log_e "Download failed"
        exit 1
    fi
    
    if [ -s /tmp/v12-tmp.sh ]; then
        sed -i 's/\r$//' /tmp/v12-tmp.sh
        if head -n 1 /tmp/v12-tmp.sh | grep -q '#!/bin/sh'; then
            cp /tmp/v12-tmp.sh "$V12_INIT"
            chmod +x "$V12_INIT"
            rm -f /tmp/v12-tmp.sh
            v12_log "Installed. Executing..."
            exec "$V12_INIT" start
        else
            v12_log_e "Invalid shebang"
            rm -f /tmp/v12-tmp.sh
            exit 1
        fi
    else
        v12_log_e "Downloaded file is empty"
        exit 1    fi
fi

# =============================================================================
# 2. PID LOCK
# =============================================================================
if [ -f "$V12_LOCK" ]; then
    OLD_PID=$(cat "$V12_LOCK" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        v12_log_w "Already running (PID $OLD_PID). Exiting."
        exit 0
    fi
    rm -f "$V12_LOCK"
fi
echo $$ > "$V12_LOCK"
trap 'rm -f "$V12_LOCK"' EXIT

# =============================================================================
# 3. LEGACY CLEANUP
# =============================================================================
v12_log "Cleaning legacy versions..."
killall -9 v8-unified-routing v9-unified-routing v10-unified-routing v11-unified-routing getdomains add-ip-subnet-routing 2>/dev/null || true

(crontab -l 2>/dev/null | grep -v -e "v8-" -e "v9-" -e "v10-" -e "v11-" -e "getdomains" -e "add-ip") | crontab - 2>/dev/null || true

uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_|\.set='vpn_domains'" | cut -d= -f1 | cut -d. -f2 | while read -r r; do
    uci delete firewall."$r" 2>/dev/null
done
uci commit firewall 2>/dev/null || true

rm -f /usr/sbin/v*-mark-rules.sh /etc/init.d/v*-unified-routing /etc/init.d/getdomains
v12_log "Legacy cleanup done."

# =============================================================================
# 4. SING-BOX EXTENDED
# =============================================================================
v12_log "Checking Sing-Box..."

FREE_MB=$(awk '/MemFree/ {printf "%d", $2/1024}' /proc/meminfo)
if [ "$FREE_MB" -lt 50 ]; then
    v12_log_w "Free RAM < 50MB. Skipping sing-box-extended download."
else
    API="https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest"
    DEST="/usr/bin/sing-box"
    SVC="sing-box"
    if [ -f "/etc/init.d/podkop" ]; then
        SVC="podkop"
    fi
    
    ARCH=$(uname -m)    if [ -f "/etc/openwrt_release" ]; then
        D_ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH")
        case "$D_ARCH" in
            *mipsel*|*mipsle*) ARCH="mipsle" ;;
            *mips64el*|*mips64le*) ARCH="mips64le" ;;
        esac
    fi
    
    case $ARCH in
        aarch64) S="arm64" ;;
        armv7*) S="armv7" ;;
        armv6*) S="armv6" ;;
        x86_64) S="amd64" ;;
        i386|i686) S="386" ;;
        mips) S="mips-softfloat" ;;
        mipsel|mipsle) S="mipsle-softfloat" ;;
        mips64) S="mips64" ;;
        mips64el|mips64le) S="mips64le" ;;
        riscv64) S="riscv64" ;;
        s390x) S="s390x" ;;
        *)
            v12_log_e "Unsupported arch $ARCH"
            S=""
            ;;
    esac
    
    if [ -n "$S" ]; then
        CUR_VER=$(/usr/bin/sing-box version 2>/dev/null | head -n 1 | awk '{print $NF}')
        
        if command -v curl >/dev/null 2>&1; then
            FETCH="curl -fsSL --insecure"
        elif command -v wget >/dev/null 2>&1; then
            FETCH="wget -qO- --no-check-certificate"
        else
            FETCH=""
        fi
        
        if [ -n "$FETCH" ]; then
            API_RESP=$($FETCH "$API" 2>/dev/null) || true
            if [ -n "$API_RESP" ]; then
                LATEST_TAG=$(echo "$API_RESP" | tr ',' '\n' | grep '"tag_name"' | head -1 | awk -F'"' '{print $4}')
                LATEST_VER=$(echo "$LATEST_TAG" | sed 's/^v//')
                
                if [ "$CUR_VER" != "$LATEST_VER" ] && [ -n "$LATEST_VER" ]; then
                    v12_log "Updating Sing-Box ($CUR_VER -> $LATEST_VER)..."
                    DL_URL=$(echo "$API_RESP" | tr ',' '\n' | grep "browser_download_url" | grep "linux-$S.tar.gz" | head -1 | awk -F'"' '{print $4}')
                    
                    if [ -n "$DL_URL" ]; then
                        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
                        mkdir -p /tmp/sb-inst && cd /tmp/sb-inst                        
                        if command -v curl >/dev/null 2>&1; then
                            curl -fsSL --insecure -o sb.tgz "$DL_URL" 2>/dev/null
                        else
                            wget -q --no-check-certificate -O sb.tgz "$DL_URL" 2>/dev/null
                        fi
                        
                        if [ -s sb.tgz ]; then
                            /etc/init.d/$SVC stop 2>/dev/null || true
                            sleep 1
                            tar -xzf sb.tgz 2>/dev/null
                            BIN=$(find . -type f -name sing-box | head -1)
                            if [ -n "$BIN" ]; then
                                mv -f "$BIN" "$DEST" 2>/dev/null && chmod +x "$DEST"
                                v12_log "✅ Sing-Box updated."
                            fi
                        fi
                        cd / && rm -rf /tmp/sb-inst
                    fi
                fi
            fi
        fi
    fi
fi

# Fix sing-box config and permissions
if [ -f "/etc/config/sing-box" ]; then
    sed -i "s/option user 'sing-box'/option user 'root'/" "/etc/config/sing-box" 2>/dev/null || true
    uci set sing-box.@sing-box[0].enabled='1' 2>/dev/null || true
    uci del sing-box.@sing-box[0].nofilelimit 2>/dev/null || true
    uci del sing-box.@sing-box[0].norlimit 2>/dev/null || true
    uci commit sing-box 2>/dev/null || true
fi

if [ ! -f /etc/sing-box/config.json ]; then
    mkdir -p /etc/sing-box
    printf '{"log":{"level":"warn"},"inbounds":[{"type":"tun","interface_name":"tun0","domain_strategy":"ipv4_only","address":["172.16.250.1/30"],"auto_route":false,"strict_route":false,"sniff":true}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"auto_detect_interface":true}}\n' > /etc/sing-box/config.json
fi

# Start sing-box if not running
if ! ps | grep -v grep | grep -q "sing-box.*run"; then
    /etc/init.d/sing-box stop 2>/dev/null || true
    sleep 1
    /etc/init.d/sing-box start 2>/dev/null || true
fi

# Wait for tun0
w=0
while [ $w -lt 20 ]; do
    if ip link show tun0 >/dev/null 2>&1; then        break
    fi
    sleep 1
    w=$((w+1))
done
if ! ip link show tun0 >/dev/null 2>&1; then
    v12_log_w "tun0 not created!"
fi

# =============================================================================
# 5. DNS & FIREWALL
# =============================================================================
v12_log "Configuring DNS & Firewall..."

if ! opkg list-installed | grep -q dnsmasq-full; then
    opkg update >/dev/null 2>&1
    cd /tmp && opkg download dnsmasq-full 2>/dev/null
    opkg remove dnsmasq 2>/dev/null
    opkg install dnsmasq-full --cache /tmp/ 2>/dev/null
    if [ -f /etc/config/dhcp-opkg ]; then
        cp /etc/config/dhcp /etc/config/dhcp-old
        mv /etc/config/dhcp-opkg /etc/config/dhcp
    fi
fi

uci del dhcp.@dnsmasq[0].noresolv 2>/dev/null || true
uci del dhcp.@dnsmasq[0].server 2>/dev/null || true
uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d' 2>/dev/null || true
uci commit dhcp 2>/dev/null || true
/etc/init.d/dnsmasq restart 2>/dev/null || true

# Create nft sets
for s in vpn_domains vpn_ip vpn_subnets vpn_community; do
    if ! nft list set inet fw4 "$s" >/dev/null 2>&1; then
        nft add set inet fw4 "$s" '{ type ipv4_addr; flags interval; }' 2>/dev/null || true
    fi
done

# Hotplug
mkdir -p /etc/hotplug.d/iface
printf '%s\n' '#!/bin/sh' '[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "tun0" ] && { sleep 5; ip route add table vpn default dev tun0 2>/dev/null || true; }' > /etc/hotplug.d/iface/30-vpnroute
chmod +x /etc/hotplug.d/iface/30-vpnroute
cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute 2>/dev/null || true

# Firewall zone
if ! uci show firewall | grep -q "@zone.*name='singbox'"; then
    uci add firewall zone
    uci set firewall.@zone[-1].name='singbox'
    uci set firewall.@zone[-1].device='tun0'
    uci set firewall.@zone[-1].forward='ACCEPT'    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].masq='1'
    uci set firewall.@zone[-1].mtu_fix='1'
    uci set firewall.@zone[-1].family='ipv4'
fi

# Forwarding
if ! uci show firewall | grep -q "@forwarding.*name='singbox-lan'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].name='singbox-lan'
    uci set firewall.@forwarding[-1].dest='singbox'
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].family='ipv4'
fi
uci commit firewall 2>/dev/null || true

# =============================================================================
# 6. DOMAINS
# =============================================================================
v12_log "Loading domains..."
mkdir -p /tmp/dnsmasq.d
DOM="/tmp/dnsmasq.d/domains.lst"
curl -f -s --max-time 60 -o "$DOM" "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst" 2>/dev/null || true

if [ -s "$DOM" ]; then
    if dnsmasq --conf-file="$DOM" --test 2>&1 | grep -q "syntax check OK"; then
        /etc/init.d/dnsmasq restart 2>/dev/null || true
        v12_log "✅ Domains loaded."
    else
        v12_log_w "Domain list syntax check failed."
    fi
fi

# =============================================================================
# 7. IP LISTS (Parallel Download -> Sequential Load)
# =============================================================================
v12_log "⚡ Downloading IP lists in parallel..."
mkdir -p /tmp/lst

# Parallel download
for pair in "ip:vpn_ip:https://antifilter.download" "subnet:vpn_subnets:https://antifilter.download" "community:vpn_community:https://community.antifilter.download"; do
    ln="${pair%%:*}"
    r="${pair#*:}"
    ls="${r%%:*}"
    lb="${r#*:}"
    curl -f -s --max-time 120 -o "/tmp/lst/${ls}.lst" "${lb}/list/${ln}.lst" &
done
wait
v12_log "✅ Downloads complete. Loading sequentially..."
# Sequential load
for ls in vpn_ip vpn_subnets vpn_community; do
    lt="/tmp/lst/${ls}.lst"
    if [ ! -s "$lt" ]; then
        continue
    fi
    
    nft flush set inet fw4 "$ls" 2>/dev/null || true
    sed 's/\r//g' "$lt" | grep -oE '[0-9.]+(/[0-9]{1,2})?' | sort -u > "/tmp/lst/${ls}.v" 2>/dev/null || true
    
    if [ ! -s "/tmp/lst/${ls}.v" ]; then
        continue
    fi
    
    cnt=0
    b=""
    done=0
    while IFS= read -r l; do
        if [ -z "$l" ]; then
            continue
        fi
        if [ -z "$b" ]; then
            b="$l"
        else
            b="${b}, ${l}"
        fi
        cnt=$((cnt+1))
        if [ "$cnt" -ge 500 ]; then
            printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/v12_b.nft
            nft -f /tmp/v12_b.nft 2>/dev/null && done=$((done+cnt))
            b=""
            cnt=0
        fi
    done < "/tmp/lst/${ls}.v"
    
    if [ -n "$b" ]; then
        printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/v12_b.nft
        nft -f /tmp/v12_b.nft 2>/dev/null && done=$((done+cnt))
    fi
    
    rm -f "$lt" "/tmp/lst/${ls}.v" /tmp/v12_b.nft
    v12_log "✅ Loaded $done into $ls."
done

# =============================================================================
# 8. MARKING RULES & ROUTE
# =============================================================================
v12_log "Applying marking rules..."
HP="/usr/sbin/v12-mark-rules.sh"
cat > "$HP" << 'HELPER'
#!/bin/sh
[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0
for c in prerouting output; do
    for s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        nft list chain inet fw4 "$c" 2>/dev/null | grep -q "v12_${s}_${c}" || \
            nft add rule inet fw4 "$c" ip daddr "@$s" meta mark set 0x1 comment "v12_${s}_${c}" 2>/dev/null || true
    done
done
HELPER
chmod +x "$HP"

if ! uci show firewall 2>/dev/null | grep -q "v12-mark-rules"; then
    uci add firewall include >/dev/null 2>&1
    uci set firewall.@include[-1].type='script'
    uci set firewall.@include[-1].path="$HP"
    uci set firewall.@include[-1].reload='1'
    uci commit firewall >/dev/null 2>&1
fi

/etc/init.d/firewall reload >/dev/null 2>&1 || true
sleep 2
"$HP"

ip route del table vpn default 2>/dev/null || true
if ip route add table vpn default dev tun0 2>/dev/null; then
    v12_log "✅ Route added: default dev tun0 table vpn"
fi

# =============================================================================
# 9. CRON
# =============================================================================
v12_log "Configuring cron..."
/etc/init.d/cron enable 2>/dev/null || true

CUR_CRON=$(crontab -l 2>/dev/null || true)
if ! echo "$CUR_CRON" | grep -q "v12-unified-routing start"; then
    { echo "$CUR_CRON"; echo "0 */12 * * * $V12_INIT start"; } | crontab - 2>/dev/null
    /etc/init.d/cron restart 2>/dev/null || true
    v12_log "✅ Cron set (12h)."
fi

v12_log "=== DONE. v12.1 active. Safe for reboot. ==="
exit 0
