#!/bin/sh
# =============================================================================
# v11.0-ultimate.sh
# Unified Routing: Domain + IP/Subnet/Community + Sing-Box Extended
#
# ФУНКЦИОНАЛ:
# 1. Очистка от legacy-скриптов (v8, v9, getdomains, etc.)
# 2. Установка Sing-Box Extended
# 3. Настройка DNSmasq (nftset domains)
# 4. Параллельная загрузка IP листов + последовательная запись в nft
# 5. Персистентные правила маркировки (переживают reboot)
# 6. Авто-установка в /etc/init.d/ при запуске через sh <(wget...)
# =============================================================================

V11_URL="https://raw.githubusercontent.com/papania777/domain-routing-openwrt-add-ips/main/all_in_one.sh"
V11_INIT="/etc/init.d/v11-unified-routing"
V11_LOCK="/tmp/v11-routing.lock"

# Цвета
C="\033[1;36m"; G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; N="\033[0m"
log() { printf "${G}[INFO]${N} %s\n" "$1"; logger -t "v11-boot" "$1"; }
log_w() { printf "${Y}[WARN]${N} %s\n" "$1"; logger -t "v11-boot" "[WARN] $1"; }
log_e() { printf "${R}[ERROR]${N} %s\n" "$1"; logger -t "v11-boot" "[ERROR] $1"; }

# =============================================================================
# 0. SAFE BOOTSTRAP & LOCKING
# =============================================================================

# Если скрипт запущен НЕ из установленного места -> Устанавливаемся
if [ "$0" != "$V11_INIT" ]; then
    echo "${C}[*] Bootstrapping v11.0...${N}"
    # Проверяем, не запущен ли уже процесс установки другого экземпляра
    if [ -f "$V11_LOCK" ]; then
        OLD_PID=$(cat "$V11_LOCK" 2>/dev/null)
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            log_w "Installation in progress (PID $OLD_PID). Waiting..."
            sleep 5
        fi
    fi
    
    # Скачиваем
    wget -q -O /tmp/v11-tmp.sh "$V11_URL" 2>/dev/null || curl -fsSL -o /tmp/v11-tmp.sh "$V11_URL" 2>/dev/null
    
    if [ -s /tmp/v11-tmp.sh ]; then
        # Убираем CRLF
        sed -i 's/\r$//' /tmp/v11-tmp.sh
        
        # Проверяем валидность
        if head -n 1 /tmp/v11-tmp.sh | grep -q '#!/bin/sh'; then
            # Копируем и включаем            cp /tmp/v11-tmp.sh "$V11_INIT"
            chmod +x "$V11_INIT"
            rm -f /tmp/v11-tmp.sh
            
            # Включаем автозагрузку
            "$V11_INIT" enable 2>/dev/null
            
            # ПЕРЕЗАПУСКАЕМ СЕБЯ из файла (exec заменяет текущий процесс)
            log "Installed. Executing from $V11_INIT..."
            exec "$V11_INIT" start
        else
            log_e "Downloaded file is invalid."
            exit 1
        fi
    else
        log_e "Failed to download script."
        exit 1
    fi
fi

# Если мы здесь - значит мы запущены как /etc/init.d/v11-unified-routing

# PID Lock
if [ -f "$V11_LOCK" ]; then
    OLD_PID=$(cat "$V11_LOCK" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log_w "Already running (PID $OLD_PID). Exiting."
        exit 0
    fi
fi
echo $$ > "$V11_LOCK"
trap 'rm -f "$V11_LOCK"' EXIT

# =============================================================================
# 1. LEGACY CLEANUP
# =============================================================================
log "Cleaning up legacy versions (v8, v9, getdomains)..."

# Убиваем старые процессы
pkill -9 -f "getdomains" 2>/dev/null
pkill -9 -f "add-ip-subnet-routing" 2>/dev/null
pkill -9 -f "v8-unified-routing" 2>/dev/null
pkill -9 -f "v9-unified-routing" 2>/dev/null

# Удаляем файлы
rm -f /etc/init.d/getdomains /etc/init.d/add-ip-subnet-routing
rm -f /etc/init.d/v8-unified-routing /etc/init.d/v9-unified-routing
rm -f /usr/sbin/v8-mark-rules.sh /usr/sbin/v9-mark-rules.sh /usr/sbin/apply-vpn-mark-rules.sh

# Чистим Cron от старых задач(crontab -l 2>/dev/null | grep -v -e "getdomains" -e "add-ip-subnet-routing" -e "v8-unified" -e "v9-unified") | crontab - 2>/dev/null

# Чистим UCI Firewall от старых ipset-правил
uci show firewall 2>/dev/null | grep -E "\.ipset='vpn_|\.set='vpn_domains'" | cut -d= -f1 | cut -d. -f2 | while read -r rule; do
    uci delete firewall."$rule" 2>/dev/null
done
uci commit firewall 2>/dev/null

# Удаляем старые темпы
rm -rf /tmp/lst/* /tmp/dnsmasq.d/* /tmp/v*_batch.nft /tmp/v11-tmp.sh
log "Cleanup done."

# =============================================================================
# 2. SYSTEM PREP
# =============================================================================

# Устанавливаем зависимости
command -v curl >/dev/null 2>&1 || { opkg update >/dev/null 2>&1; opkg install curl >/dev/null 2>&1; }
command -v nft >/dev/null 2>&1 || { log_e "nft missing!"; exit 1; }

# Настройка маршрутизации
sed -i '/^[[:space:]]*99[[:space:]]*vpn/d' /etc/iproute2/rt_tables 2>/dev/null
echo '99 vpn' >> /etc/iproute2/rt_tables

# Правило маркировки
uci show network 2>/dev/null | grep -q "mark='0x1'" || {
    uci add network rule >/dev/null 2>&1
    uci set network.@rule[-1].name='mark0x1'
    uci set network.@rule[-1].mark='0x1'
    uci set network.@rule[-1].priority='100'
    uci set network.@rule[-1].lookup='vpn'
    uci commit network 2>/dev/null
}

# DNS: Устанавливаем dnsmasq-full, отключаем конкуренты
command -v dnscrypt-proxy >/dev/null 2>&1 && { /etc/init.d/dnscrypt-proxy disable 2>/dev/null; /etc/init.d/dnscrypt-proxy stop 2>/dev/null; }
command -v stubby >/dev/null 2>&1 && { /etc/init.d/stubby disable 2>/dev/null; /etc/init.d/stubby stop 2>/dev/null; }

if ! opkg list-installed | grep -q dnsmasq-full; then
    log "Installing dnsmasq-full..."
    opkg update >/dev/null 2>&1
    cd /tmp && opkg download dnsmasq-full 2>/dev/null
    opkg remove dnsmasq 2>/dev/null
    opkg install dnsmasq-full --cache /tmp/ 2>/dev/null
    [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
fi

# Сброс настроек DNS на дефолтные (чтобы не было конфликтов)
uci del dhcp.@dnsmasq[0].noresolv 2>/dev/null
uci del dhcp.@dnsmasq[0].server 2>/dev/nulluci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d' 2>/dev/null
uci commit dhcp 2>/dev/null
/etc/init.d/dnsmasq restart 2>/dev/null

# =============================================================================
# 3. SING-BOX EXTENDED
# =============================================================================
log "Checking Sing-Box..."
SVC="sing-box"; [ -f "/etc/init.d/podkop" ] && SVC="podkop"

# Устанавливаем пакет, если нет
if ! opkg list-installed | grep -q sing-box; then
    opkg install sing-box >/dev/null 2>&1
fi

# Логика обновления на Extended (из install.sh)
if command -v curl >/dev/null 2>&1; then FETCH="curl -fsSL --insecure"; DL="curl -fsSL --insecure -o"
elif command -v wget >/dev/null 2>&1; then FETCH="wget -qO- --no-check-certificate"; DL="wget -q --no-check-certificate -O"
else log_e "No curl/wget"; exit 1; fi

HOST_ARCH=$(uname -m)
[ -f "/etc/openwrt_release" ] && DISTRIB_ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH") && \
    case "$DISTRIB_ARCH" in *mipsel*|*mipsle*) HOST_ARCH="mipsel";; *mips64el*|*mips64le*) HOST_ARCH="mips64el";; esac

case $HOST_ARCH in
    aarch64) ARCH="arm64";; armv7*) ARCH="armv7";; armv6*) ARCH="armv6";;
    x86_64) ARCH="amd64";; i386|i686) ARCH="386";; mips) ARCH="mips-softfloat";;
    mipsel|mipsle) ARCH="mipsle-softfloat";; mips64) ARCH="mips64";;
    mips64el|mips64le) ARCH="mips64le";; riscv64) ARCH="riscv64";; s390x) ARCH="s390x";;
    *) log_e "Unsupported arch $HOST_ARCH"; exit 1;;
esac

# Проверяем версию, чтобы не качать зря
INSTALLED_VER=$(/usr/bin/sing-box version 2>/dev/null | head -n 1 | awk '{print $NF}')
LATEST_TAG=$($FETCH "https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest" 2>/dev/null | tr ',' '\n' | grep '"tag_name"' | head -n 1 | awk -F'"' '{print $4}')
LATEST_VER=$(echo "$LATEST_TAG" | sed 's/^v//')

if [ "$INSTALLED_VER" != "$LATEST_VER" ] && [ -n "$LATEST_VER" ]; then
    log "Updating Sing-Box ($INSTALLED_VER -> $LATEST_VER)..."
    DOWNLOAD_URL=$($FETCH "https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest" 2>/dev/null | tr ',' '\n' | grep "browser_download_url" | grep "linux-$ARCH.tar.gz" | head -1 | awk -F'"' '{print $4}')
    
    if [ -n "$DOWNLOAD_URL" ]; then
        mkdir -p /tmp/sb-install && cd /tmp/sb-install
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        
        $DL "sb.tar.gz" "$DOWNLOAD_URL" 2>/dev/null
        /etc/init.d/$SVC stop 2>/dev/null; sleep 1
        
        if [ -s "sb.tar.gz" ]; then
            tar -xzf "sb.tar.gz"            BINARY=$(find . -type f -name sing-box | head -n 1)
            if [ -n "$BINARY" ]; then
                mv -f "$BINARY" /usr/bin/sing-box && chmod +x /usr/bin/sing-box
                log "✅ Sing-Box Extended installed."
            fi
        fi
        cd /; rm -rf /tmp/sb-install
    fi
fi

# Фикс конфига и прав
[ -f "/etc/config/$SVC" ] && {
    sed -i "s/option user 'sing-box'/option user 'root'/" "/etc/config/$SVC" 2>/dev/null
    uci set "$SVC.@$SVC[0].enabled"='1' 2>/dev/null
    uci del "$SVC.@$SVC[0].nofilelimit" 2>/dev/null
    uci del "$SVC.@$SVC[0].norlimit" 2>/dev/null
    uci commit "$SVC" 2>/dev/null
}

# Создаем конфиг, если нет
[ ! -f /etc/sing-box/config.json ] && {
    mkdir -p /etc/sing-box
    printf '{"log":{"level":"warn"},"inbounds":[{"type":"tun","interface_name":"tun0","domain_strategy":"ipv4_only","address":["172.16.250.1/30"],"auto_route":false,"strict_route":false,"sniff":true}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"auto_detect_interface":true}}\n' > /etc/sing-box/config.json
}

# Запуск
if ! ps | grep -v grep | grep -q "sing-box.*run"; then
    /etc/init.d/$SVC stop 2>/dev/null; sleep 1
    /etc/init.d/$SVC start 2>/dev/null
fi

# Ждем tun0
w=0; while [ $w -lt 20 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; w=$((w+1)); done
ip link show tun0 >/dev/null 2>&1 || log_w "tun0 not created!"

# =============================================================================
# 4. FIREWALL SETUP
# =============================================================================
log "Configuring Firewall..."

# Создаем сеты
for s in vpn_domains vpn_ip vpn_subnets vpn_community; do
    nft list set inet fw4 "$s" >/dev/null 2>&1 || nft add set inet fw4 "$s" '{ type ipv4_addr; flags interval; }' 2>/dev/null
done

# Zone
uci show firewall | grep -q "@zone.*name='singbox'" || {
    uci add firewall zone
    uci set firewall.@zone[-1].name='singbox'
    uci set firewall.@zone[-1].device='tun0'    uci set firewall.@zone[-1].forward='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].masq='1'
    uci set firewall.@zone[-1].mtu_fix='1'
    uci set firewall.@zone[-1].family='ipv4'
    uci commit firewall
}

# Forwarding
uci show firewall | grep -q "@forwarding.*name='singbox-lan'" || {
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].name='singbox-lan'
    uci set firewall.@forwarding[-1].dest='singbox'
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].family='ipv4'
    uci commit firewall
}

# Hotplug
mkdir -p /etc/hotplug.d/iface
printf '%s\n' '#!/bin/sh' '[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "tun0" ] && { sleep 5; ip route add table vpn default dev tun0 2>/dev/null || true; }' > /etc/hotplug.d/iface/30-vpnroute
chmod +x /etc/hotplug.d/iface/30-vpnroute
cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute 2>/dev/null

# =============================================================================
# 5. DOMAIN ROUTING
# =============================================================================
log "Loading Domains..."
mkdir -p /tmp/dnsmasq.d
DOM_FILE="/tmp/dnsmasq.d/domains.lst"
curl -f -s --max-time 60 -o "$DOM_FILE" "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst" 2>/dev/null || true

if [ -s "$DOM_FILE" ] && dnsmasq --conf-file="$DOM_FILE" --test 2>&1 | grep -q "syntax check OK"; then
    /etc/init.d/dnsmasq restart 2>/dev/null
    log "✅ Domains loaded."
else
    log_w "Domain list syntax check failed or download error."
fi

# =============================================================================
# 6. IP LISTS (Parallel Download -> Sequential Load)
# =============================================================================
log "⚡ Downloading IP lists in PARALLEL..."
mkdir -p /tmp/lst

# Скачиваем параллельно
for pair in "ip:vpn_ip:https://antifilter.download" "subnet:vpn_subnets:https://antifilter.download" "community:vpn_community:https://community.antifilter.download"; do
    ln="${pair%%:*}"; r="${pair#*:}"; ls="${r%%:*}"; lb="${r#*:}"
    curl -f -s --max-time 120 -o "/tmp/lst/${ls}.lst" "${lb}/list/${ln}.lst" &done
wait # Ждем окончания всех загрузок
log "✅ Downloads complete. Loading SEQUENTIALLY (RAM-safe)..."

# Загружаем последовательно
for pair in "ip:vpn_ip" "subnet:vpn_subnets" "community:vpn_community"; do
    ls="${pair#*:}"
    lt="/tmp/lst/${ls}.lst"
    [ -s "$lt" ] || continue
    
    # Очищаем сет
    nft flush set inet fw4 "$ls" 2>/dev/null || true
    
    # Парсим в валидный файл (удаляем мусор, дубли)
    sed 's/\r//g' "$lt" | grep -oE '[0-9.]+(/[0-9]{1,2})?' | sort -u > "/tmp/lst/${ls}.valid" 2>/dev/null
    [ -s "/tmp/lst/${ls}.valid" ] || { log_w "No valid IPs in $ls"; continue; }
    
    # Пишем батчами по 500
    cnt=0; b=""; done=0
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        [ -z "$b" ] && b="$l" || b="${b}, ${l}"
        cnt=$((cnt+1))
        if [ "$cnt" -ge 500 ]; then
            printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/v11_batch.nft
            nft -f /tmp/v11_batch.nft 2>/dev/null && done=$((done+cnt))
            b=""; cnt=0
            sync # Сброс кэша для экономии RAM
        fi
    done < "/tmp/lst/${ls}.valid"
    
    # Дописываем остаток
    [ -n "$b" ] && printf 'add element inet fw4 %s { %s }\n' "$ls" "$b" > /tmp/v11_batch.nft && nft -f /tmp/v11_batch.nft 2>/dev/null && done=$((done+cnt))
    
    rm -f "$lt" "/tmp/lst/${ls}.valid" /tmp/v11_batch.nft
    log "✅ Loaded $done entries into $ls."
done

# =============================================================================
# 7. MARKING RULES & ROUTE
# =============================================================================
log "Applying Marking Rules..."
HP="/usr/sbin/v11-mark-rules.sh"

# Создаем скрипт восстановления правил
cat > "$HP" << 'HELPER'
#!/bin/sh
[ -z "$(nft list table inet fw4 2>/dev/null)" ] && exit 0
for c in prerouting output; do
    for s in vpn_domains vpn_ip vpn_subnets vpn_community; do        nft list chain inet fw4 "$c" 2>/dev/null | grep -q "v11_${s}_${c}" || \
            nft add rule inet fw4 "$c" ip daddr "@$s" meta mark set 0x1 comment "v11_${s}_${c}" 2>/dev/null || true
    done
done
HELPER
chmod +x "$HP"

# Регистрируем в UCI (чтобы работало после ребута)
uci show firewall 2>/dev/null | grep -q "v11-mark-rules" || {
    uci add firewall include >/dev/null 2>&1
    uci set firewall.@include[-1].type='script'
    uci set firewall.@include[-1].path="$HP"
    uci set firewall.@include[-1].reload='1'
    uci commit firewall >/dev/null 2>&1
}

# Применяем сейчас
"$HP"

# Маршрут
ip route del table vpn default 2>/dev/null
ip route add table vpn default dev tun0 2>/dev/null && log "✅ Route added: default dev tun0 table vpn"

# =============================================================================
# 8. CRON
# =============================================================================
log "Configuring Cron..."
/etc/init.d/cron enable 2>/dev/null || true
if ! crontab -l 2>/dev/null | grep -q "v11-unified-routing start"; then
    (crontab -l 2>/dev/null || true; echo "0 */12 * * * $V11_INIT start") | crontab - 2>/dev/null
    /etc/init.d/cron restart 2>/dev/null || true
    log "✅ Cron set (update every 12h)."
fi

log "=== DONE. System v11.0 ready. ==="
exit 0
