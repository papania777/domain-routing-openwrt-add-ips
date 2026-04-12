#!/bin/sh
# =============================================================================
# v8.7-boot-order-fix.sh
# Unified Routing: Domain + IP/Subnet/Community + Sing-Box Extended
# ИСПРАВЛЕНО: Порядок запуска при буте, проверка готовности, логирование
# =============================================================================

V8_SCRIPT_URL="https://raw.githubusercontent.com/papania777/domain-routing-openwrt-add-ips/refs/heads/main/all_in_one.sh"

v8_green='\033[32;1m'; v8_red='\033[31;1m'; v8_yellow='\033[33;1m'; v8_nc='\033[0m'
v8_log_i() { printf "${v8_green}[INFO]${v8_nc} %s\n" "$1"; }
v8_log_w() { printf "${v8_yellow}[WARN]${v8_nc} %s\n" "$1"; }
v8_log_e() { printf "${v8_red}[ERROR]${v8_nc} %s\n" "$1"; }
v8_log_boot() { logger -t "v8-boot" "$1"; }  # <-- Логирование в system log для отладки

# =============================================================================
# PHASE 0: SELF-INSTALL & CRON
# =============================================================================
v8_self_install() {
    v8_log_i "Phase 0: Self-installing & configuring cron..."
    v8_init_path="/etc/init.d/v8-unified-routing"
    v8_tmp_path="/tmp/v8-install-check.sh"

    if [ -x "$v8_init_path" ]; then
        v8_log_i "Script already installed."
    else
        if wget -q -O "$v8_tmp_path" "$V8_SCRIPT_URL" 2>/dev/null; then
            sed -i 's/\r$//' "$v8_tmp_path"
            if head -n 1 "$v8_tmp_path" | grep -q '#!/bin/sh'; then
                cp "$v8_tmp_path" "$v8_init_path"
                chmod +x "$v8_init_path"
                rm -f "$v8_tmp_path"
                "$v8_init_path" enable 2>/dev/null || true
                v8_log_i "✅ Installed & enabled."
            else
                v8_log_w "Invalid download. Skipping auto-install."
                rm -f "$v8_tmp_path"
            fi
        else
            v8_log_w "Download failed. Manual install required."
        fi
    fi

    /etc/init.d/cron enable 2>/dev/null || true
    if ! crontab -l 2>/dev/null | grep -q "v8-unified-routing start"; then
        v8_cur=$(crontab -l 2>/dev/null || true)
        echo "$v8_cur
0 */12 * * * $v8_init_path start" | crontab - 2>/dev/null
        /etc/init.d/cron restart 2>/dev/null || true
        v8_log_i "✅ Cron job added (every 12h)"
    fi
}

# =============================================================================
# PHASE 1: GENERAL CLEANUP
# =============================================================================
v8_cleanup() {
    v8_log_i "Phase 1: General cleanup..."
    [ -f /etc/sing-box/config.json ] && cp /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)" 2>/dev/null
    crontab -l 2>/dev/null | grep -v -e "add-ip-subnet-routing" -e "getdomains" -e "v8-unified" | crontab - 2>/dev/null || true
    for v8_r in $(uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_|\.set='vpn_domains'" | cut -d= -f1 | cut -d. -f2); do
        uci delete firewall."$v8_r" >/dev/null 2>&1
    done
    uci commit firewall >/dev/null 2>&1
    rm -f /usr/sbin/v8-mark-rules.sh
    rm -rf /tmp/lst/* /tmp/dnsmasq.d/* /tmp/v8_batch.nft /tmp/sing-box-*
    v8_log_i "General cleanup done."
}

# =============================================================================
# PHASE 2: PRE-CREATE NFT SETS
# =============================================================================
v8_create_sets() {
    v8_log_i "Phase 2: Pre-creating nft sets..."
    for v8_s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        nft list set inet fw4 "$v8_s" >/dev/null 2>&1 || \
            nft add set inet fw4 "$v8_s" '{ type ipv4_addr; flags interval; }' 2>/dev/null || \
            v8_log_e "Failed to create set $v8_s"
    done
}

# =============================================================================
# PHASE 3: VALIDATE & REPAIR
# =============================================================================
v8_validate() {
    v8_log_i "Phase 3: Validate system..."
    command -v curl >/dev/null 2>&1 || { v8_log_e "curl missing"; exit 1; }
    command -v nft  >/dev/null 2>&1 || { v8_log_e "nft missing"; exit 1; }
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
}

# =============================================================================
# PHASE 3.5: CLEANUP LEGACY DNS RESOLVERS
# =============================================================================
v8_cleanup_dns() {
    v8_log_i "Phase 3.5: Cleaning up legacy DNS resolvers..."
    v8_dns_cleaned=0
    if command -v dnscrypt-proxy >/dev/null 2>&1 || opkg list-installed | grep -q dnscrypt-proxy2; then
        /etc/init.d/dnscrypt-proxy stop 2>/dev/null || true
        /etc/init.d/dnscrypt-proxy disable 2>/dev/null || true
        v8_dns_cleaned=1
    fi
    if command -v stubby >/dev/null 2>&1 || opkg list-installed | grep -q stubby; then
        /etc/init.d/stubby stop 2>/dev/null || true
        /etc/init.d/stubby disable 2>/dev/null || true
        v8_dns_cleaned=1
    fi
    if [ "$v8_dns_cleaned" -eq 1 ] || uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null | grep -q "1"; then
        uci del dhcp.@dnsmasq[0].noresolv 2>/dev/null || true
        uci del dhcp.@dnsmasq[0].server 2>/dev/null || true
        uci commit dhcp 2>/dev/null || true
        /etc/init.d/dnsmasq restart 2>/dev/null || true
        v8_log_i "Default DNS restored."
    fi
}

# =============================================================================
# PHASE 4: DNSMASQ & DOMAIN ROUTING
# =============================================================================
v8_setup_domains() {
    v8_log_i "Phase 4: DNSmasq & Domain Routing..."
    if ! opkg list-installed | grep -q dnsmasq-full; then
        opkg update >/dev/null 2>&1
        cd /tmp && opkg download dnsmasq-full 2>/dev/null
        opkg remove dnsmasq 2>/dev/null && opkg install dnsmasq-full --cache /tmp 2>/dev/null
        [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
    fi
    uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d' 2>/dev/null
    uci commit dhcp 2>/dev/null
    mkdir -p /tmp/dnsmasq.d

    v8_dom_url="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst"
    v8_dom_file="/tmp/dnsmasq.d/domains.lst"
    if curl -f -s --max-time 120 -o "$v8_dom_file" "$v8_dom_url" 2>/dev/null && [ -s "$v8_dom_file" ]; then
        if dnsmasq --conf-file="$v8_dom_file" --test 2>&1 | grep -q "syntax check OK"; then
            /etc/init.d/dnsmasq stop 2>/dev/null; /etc/init.d/dnsmasq start 2>/dev/null
            sleep 3
            grep -oE 'nftset=/[^/]+/' "$v8_dom_file" 2>/dev/null | head -3 | sed 's|nftset=/||; s|/||' | while read v8_d; do
                [ -n "$v8_d" ] && nslookup "$v8_d" 127.0.0.1 >/dev/null 2>&1 &
            done
            wait
            v8_log_i "Domain routing configured."
        else
            v8_log_e "Domain list syntax check FAILED."
        fi
    else
        v8_log_w "Failed to download domain list."
    fi
}

# =============================================================================
# PHASE 5: FIREWALL UCI & HOTPLUG
# =============================================================================
v8_setup_fw() {
    v8_log_i "Phase 5: Firewall UCI & Hotplug..."
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/30-vpnroute << 'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "tun0" ] && {
    logger -t "v8-boot" "tun0 came up, adding route"
    sleep 10
    ip route add table vpn default dev tun0 2>/dev/null || true
}
EOF
    chmod +x /etc/hotplug.d/iface/30-vpnroute
    cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute 2>/dev/null || true

    uci show firewall | grep -q "@zone.*name='singbox'" || {
        uci add firewall zone
        uci set firewall.@zone[-1].name='singbox'
        uci set firewall.@zone[-1].device='tun0'
        uci set firewall.@zone[-1].forward='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    }
    uci show firewall | grep -q "@forwarding.*name='singbox-lan'" || {
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].name='singbox-lan'
        uci set firewall.@forwarding[-1].dest='singbox'
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    }
}

# =============================================================================
# PHASE 6: SING-BOX & EXTENDED (FIXED TUN PERMISSIONS)
# =============================================================================
v8_install_extended() {
    v8_log_i "Installing/Updating sing-box-extended..."
    v8_host_arch=$(uname -m)
    if [ -f "/etc/openwrt_release" ]; then
        v8_dist_arch=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH")
        case "$v8_dist_arch" in *mipsel*|*mipsle*) v8_host_arch="mipsel" ;; *mips64el*|*mips64le*) v8_host_arch="mips64el" ;; esac
    fi
    case $v8_host_arch in
        aarch64) v8_arch="arm64" ;; armv7*) v8_arch="armv7" ;; armv6*) v8_arch="armv6" ;;
        x86_64) v8_arch="amd64" ;; i386|i686) v8_arch="386" ;; mips) v8_arch="mips-softfloat" ;;
        mipsel|mipsle) v8_arch="mipsle-softfloat" ;; mips64) v8_arch="mips64" ;;
        mips64el|mips64le) v8_arch="mips64le" ;; riscv64) v8_arch="riscv64" ;; s390x) v8_arch="s390x" ;; *) v8_log_e "Unsupported arch"; return 1 ;;
    esac

    v8_api="https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest"
    v8_res=$(curl -fsSL --insecure "$v8_api" 2>/dev/null || wget -qO- --no-check-certificate "$v8_api" 2>/dev/null)
    [ -z "$v8_res" ] && { v8_log_w "GitHub API unreachable. Using existing binary."; return 0; }

    v8_url=$(echo "$v8_res" | grep "browser_download_url" | grep "linux-$v8_arch.tar.gz" | head -1 | awk -F '"' '{print $4}')
    [ -z "$v8_url" ] && { v8_log_w "No binary for $v8_arch. Keeping current."; return 0; }

    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    cd /tmp
    curl -fsSL --insecure -o sing-box-ext.tar.gz "$v8_url" 2>/dev/null || wget -q --no-check-certificate -O sing-box-ext.tar.gz "$v8_url" 2>/dev/null
    [ -s sing-box-ext.tar.gz ] || { v8_log_w "Download failed"; return 0; }

    tar -xzf sing-box-ext.tar.gz 2>/dev/null
    v8_bin=$(find . -type f -name sing-box | head -n 1)
    if [ -n "$v8_bin" ]; then
        killall sing-box 2>/dev/null || true
        sleep 1
        cp -f "$v8_bin" /usr/bin/sing-box
        chmod +x /usr/bin/sing-box
        v8_log_i "✅ sing-box-extended binary replaced."
    fi
    rm -f sing-box-ext.tar.gz && rm -rf ./sing-box*
    cd /
}

v8_fix_singbox_permissions() {
    v8_log_i "Fixing sing-box permissions for TUN interface..."
    v8_service="sing-box"
    [ -f "/etc/init.d/podkop" ] && v8_service="podkop"
    
    if [ -f "/etc/config/$v8_service" ]; then
        if grep -q "option user 'sing-box'" "/etc/config/$v8_service" 2>/dev/null; then
            sed -i "s/option user 'sing-box'/option user 'root'/" "/etc/config/$v8_service" 2>/dev/null
        fi
        uci set "$v8_service.@$v8_service[0].enabled"='1' 2>/dev/null || true
        uci del "$v8_service.@$v8_service[0].nofilelimit" 2>/dev/null || true
        uci del "$v8_service.@$v8_service[0].norlimit" 2>/dev/null || true
        uci commit "$v8_service" 2>/dev/null || true
    fi
    chmod 755 /usr/bin/sing-box 2>/dev/null || true
    /etc/init.d/$v8_service stop 2>/dev/null || true
    rm -f /var/run/$v8_service.* 2>/dev/null || true
}

v8_setup_singbox() {
    v8_log_i "Phase 6: Sing-Box setup & validation..."
    if ! opkg list-installed | grep -q sing-box; then
        opkg update >/dev/null 2>&1
        opkg install sing-box >/dev/null 2>&1 || { v8_log_e "sing-box package failed"; exit 1; }
    fi
    v8_install_extended
    v8_fix_singbox_permissions

    if [ ! -f /etc/sing-box/config.json ]; then
        mkdir -p /etc/sing-box
        cat > /etc/sing-box/config.json << 'SBEOF'
{"log":{"level":"debug"},"inbounds":[{"type":"tun","interface_name":"tun0","domain_strategy":"ipv4_only","address":["172.16.250.1/30"],"auto_route":false,"strict_route":false,"sniff":true}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"auto_detect_interface":true}}
SBEOF
        v8_log_i "Default config created. EDIT outbounds TO SET YOUR PROXY!"
    else
        v8_log_i "Existing config preserved."
    fi

    sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 || v8_log_w "Config check failed."

    v8_service="sing-box"
    [ -f "/etc/init.d/podkop" ] && v8_service="podkop"
    
    /etc/init.d/$v8_service stop 2>/dev/null || true
    sleep 2
    /etc/init.d/$v8_service start 2>/dev/null || true
    sleep 3

    if ! ps | grep -v grep | grep -q "sing-box.*run"; then
        v8_log_w "Init script didn't spawn process. Starting directly as root..."
        killall sing-box 2>/dev/null || true
        sleep 1
        nohup /usr/bin/sing-box run -c /etc/sing-box/config.json >/tmp/sb-stdout.log 2>/tmp/sb-stderr.log &
        v8_log_i "✅ Direct process started (PID: $!)"
    fi

    v8_tun_wait=0
    while [ $v8_tun_wait -lt 30 ]; do
        if ip link show tun0 >/dev/null 2>&1; then
            v8_log_i "✅ Sing-Box running. tun0 interface created."
            return 0
        fi
        sleep 1
        v8_tun_wait=$((v8_tun_wait + 1))
    done
    v8_log_e "tun0 not created after 30s. Check logs:"
    [ -s /tmp/sb-stderr.log ] && cat /tmp/sb-stderr.log | head -15
}

# =============================================================================
# PHASE 7: LOAD IP LISTS
# =============================================================================
v8_load_list() {
    v8_ln="$1"; v8_ls="$2"; v8_lb="${3:-https://antifilter.download}"
    v8_lu="${v8_lb}/list/${v8_ln}.lst"; v8_lt="/tmp/lst/${v8_ls}.lst"
    mkdir -p /tmp/lst
    curl -f -s --max-time 120 -o "$v8_lt" "$v8_lu" 2>/dev/null || return 1
    [ -s "$v8_lt" ] || return 1
    nft flush set inet fw4 "$v8_ls" 2>/dev/null || true
    sed 's/\r//g' "$v8_lt" | grep -oE '[0-9.]+(/[0-9]{1,2})?' | sort -u > /tmp/lst/${v8_ls}.valid 2>/dev/null || true
    [ -s /tmp/lst/${v8_ls}.valid ] || return 1
    v8_cnt=0; v8_b=""; v8_done=0
    while IFS= read -r v8_l; do
        [ -z "$v8_l" ] && continue
        [ -z "$v8_b" ] && v8_b="$v8_l" || v8_b="${v8_b}, ${v8_l}"
        v8_cnt=$((v8_cnt+1))
        if [ "$v8_cnt" -ge 500 ]; then
            printf 'add element inet fw4 %s { %s }\n' "$v8_ls" "$v8_b" > /tmp/v8_batch.nft
            nft -f /tmp/v8_batch.nft 2>/dev/null && v8_done=$((v8_done+v8_cnt))
            v8_b=""; v8_cnt=0
        fi
    done < /tmp/lst/${v8_ls}.valid
    if [ -n "$v8_b" ]; then
        printf 'add element inet fw4 %s { %s }\n' "$v8_ls" "$v8_b" > /tmp/v8_batch.nft
        nft -f /tmp/v8_batch.nft 2>/dev/null && v8_done=$((v8_done+v8_cnt))
    fi
    rm -f "$v8_lt" /tmp/lst/${v8_ls}.valid /tmp/v8_batch.nft
    v8_log_i "Loaded ~$v8_done into $v8_ls."
}
v8_load_all() {
    v8_log_i "Phase 7: Loading IP lists..."
    v8_load_list "ip" "vpn_ip" "https://antifilter.download" &
    v8_p1=$!; v8_load_list "subnet" "vpn_subnets" "https://antifilter.download" &
    v8_p2=$!; v8_load_list "community" "vpn_community" "https://community.antifilter.download" &
    v8_p3=$!
    wait $v8_p1 $v8_p2 $v8_p3 2>/dev/null
}

# =============================================================================
# PHASE 8: APPLY RULES & PERSISTENCE (WITH BOOT ORDER FIX)
# =============================================================================
v8_apply_rules() {
    v8_log_i "Phase 8: Firewall reload & marking rules..."
    v8_hp="/usr/sbin/v8-mark-rules.sh"
    cat > "$v8_hp" << 'HELPER'
#!/bin/sh
[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0
for v8c in prerouting output; do
    for v8s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        nft list chain inet fw4 "$v8c" 2>/dev/null | grep -q "v8_${v8s}_${v8c}" || \
            nft add rule inet fw4 "$v8c" ip daddr "@$v8s" meta mark set 0x1 comment "v8_${v8s}_${v8c}" 2>/dev/null || true
    done
done
HELPER
    chmod +x "$v8_hp"
    if ! uci show firewall 2>/dev/null | grep -q "v8-mark-rules"; then
        uci add firewall include >/dev/null 2>&1
        uci set firewall.@include[-1].type='script'
        uci set firewall.@include[-1].path="$v8_hp"
        uci set firewall.@include[-1].reload='1'
        uci commit firewall >/dev/null 2>&1
    fi
    
    # 🔑 КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ: ждём готовности перед применением правил
    v8_log_boot "Waiting for sets to be populated..."
    v8_ready_wait=0
    while [ $v8_ready_wait -lt 60 ]; do
        v8_domains_cnt=$(nft list set inet fw4 vpn_domains 2>/dev/null | grep -cE "^\s+[0-9]" || echo 0)
        v8_ip_cnt=$(nft list set inet fw4 vpn_ip 2>/dev/null | grep -cE "^\s+[0-9]" || echo 0)
        if [ "$v8_ip_cnt" -gt 1000 ] && [ "$v8_domains_cnt" -gt 0 ]; then
            v8_log_boot "Sets ready: domains=$v8_domains_cnt, ip=$v8_ip_cnt"
            break
        fi
        sleep 1
        v8_ready_wait=$((v8_ready_wait + 1))
    done
    
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    sleep 3
    
    # 🔑 Явно применяем правила после reload
    "$v8_hp"
    v8_log_i "Marking rules active & persistent."
    v8_log_boot "Marking rules applied after firewall reload"
}

# =============================================================================
# PHASE 9: ROUTE (WITH BOOT ORDER FIX)
# =============================================================================
v8_setup_route() {
    v8_log_i "Phase 9: Route setup..."
    
    # 🔑 Если tun0 уже есть — добавляем маршрут сразу
    if ip link show tun0 >/dev/null 2>&1; then
        ip route del table vpn default 2>/dev/null || true
        ip route add table vpn default dev tun0 2>/dev/null && v8_log_i "Route: default dev tun0 table vpn"
        v8_log_boot "Route added: default dev tun0 table vpn"
    else
        v8_log_w "tun0 not ready yet. Hotplug will add route when interface comes up."
        v8_log_boot "tun0 not ready, relying on hotplug"
    fi
}

# =============================================================================
# DIAGNOSTICS
# =============================================================================
v8_diagnose() {
    echo "=== NFT SETS (IP COUNT) ==="
    for v8_s in vpn_domains vpn_ip vpn_subnets vpn_community; do
        v8_cnt=$(nft list set inet fw4 "$v8_s" 2>/dev/null | grep -cE "^\s+[0-9]" || echo 0)
        printf "%-20s %s IPs\n" "$v8_s:" "$v8_cnt"
    done
    v8_dc=0
    [ -s /tmp/dnsmasq.d/domains.lst ] && v8_dc=$(grep -c "^nftset=" /tmp/dnsmasq.d/domains.lst 2>/dev/null || echo 0)
    printf "\n%-20s %s domains (nftset lines)\n" "Domains list:" "$v8_dc"
    
    echo -e "\n=== MARKING RULES ==="
    v8_rc=$(nft list ruleset 2>/dev/null | grep -c "v8_")
    echo "Found: $v8_rc rules"
    echo -e "\n=== IP RULE ==="
    ip rule 2>/dev/null | grep "0x1" || echo "Not found"
    echo -e "\n=== VPN ROUTE ==="
    ip route show table vpn 2>/dev/null || echo "Empty"
    echo -e "\n=== SING-BOX ==="
    /etc/init.d/sing-box status 2>&1 | head -3
    echo -e "\n=== SING-BOX PROCESS ==="
    ps | grep -v grep | grep sing-box || echo "No sing-box process found"
    echo -e "\n=== TUN INTERFACE ==="
    ip link show tun0 2>/dev/null || echo "tun0 not found"
    echo -e "\n=== DNS TEST ==="
    if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then echo "✅ Works"; else echo "❌ Failed"; fi
    echo -e "\n=== CRON & INIT ==="
    crontab -l 2>/dev/null | grep "v8-unified" || echo "❌ Not in cron"
    [ -x /etc/init.d/v8-unified-routing ] && echo "✅ Installed in init.d" || echo "❌ Not installed"
    echo -e "\n=== BOOT LOGS (last 10) ==="
    logread | grep "v8-boot" | tail -10 || echo "No boot logs found"
}

# =============================================================================
# MAIN
# =============================================================================
v8_main() {
    v8_log_boot "=== Script start ==="
    echo "============================================================"
    echo "  Unified Routing v8.7 (Boot Order Fix + Logging)"
    echo "============================================================"
    v8_self_install
    v8_create_sets
    v8_cleanup
    v8_validate
    v8_cleanup_dns
    v8_setup_domains
    v8_setup_fw
    v8_setup_singbox
    v8_load_all
    v8_apply_rules
    v8_setup_route
    v8_diagnose
    v8_log_boot "=== Script end ==="
    echo "============================================================"
    v8_log_i "DONE. All components active. Routing ready."
    echo "Manage: /etc/init.d/v8-unified-routing {start|stop|restart|diagnose}"
    echo "Debug: logread | grep v8-boot"
    echo "============================================================"
}

# =============================================================================
# INIT SCRIPT INTERFACE (for /etc/init.d/)
# =============================================================================
# Этот блок позволяет скрипту работать как init-скрипт с правильным приоритетом
if [ "${1:-}" = "boot" ] || [ -x /etc/rc.common ] && /etc/rc.common boot; then
    # При загрузке системы: ждём готовности сети перед запуском
    v8_log_boot "Boot mode: waiting for network..."
    for v8_i in 1 2 3 4 5; do
        if ip link show lo >/dev/null 2>&1; then break; fi
        sleep 2
    done
    v8_main
    exit 0
fi

v8_cmd="${1:-start}"
case "$v8_cmd" in
    start) v8_main ;;
    clean) v8_cleanup; v8_cleanup_dns; v8_log_i "Cleanup done." ;;
    stop) for v8_s in vpn_domains vpn_ip vpn_subnets vpn_community; do nft flush set inet fw4 "$v8_s" 2>/dev/null || true; done ;;
    reload|restart) "$0" stop; sleep 1; "$0" start ;;
    diagnose) v8_diagnose ;;
    *) echo "Usage: $0 {start|clean|stop|reload|restart|diagnose}"; exit 1 ;;
esac
exit 0