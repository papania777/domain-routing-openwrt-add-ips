#!/bin/sh
# =============================================================================
# add-ip-subnet-routing.sh v1.1 (исправленная версия)
# Дополнение к domain-routing-openwrt: добавляет маршрутизацию по list_ip и list_subnet
# Источник списков: https://antifilter.download
# Совместимость: OpenWrt 23.05+, fw4 (nftables)
# =============================================================================

# Не используем set -e, чтобы контролировать ошибки вручную
# set -e  # <-- УБРАНО: вызывает преждевременный выход при ошибках в grep, nft и т.д.

# Цвета для вывода
GREEN='\033[32;1m'
RED='\033[31;1m'
YELLOW='\033[33;1m'
NC='\033[0m'

log_info()    { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# =============================================================================
# Проверка зависимостей и базовой настройки
# =============================================================================

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Проверка curl
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl not found. Installing..."
        opkg update >/dev/null 2>&1 && opkg install curl >/dev/null 2>&1 || {
            log_error "Failed to install curl. Exit."
            exit 1
        }
    fi
    
    # Проверка nftables
    if ! command -v nft >/dev/null 2>&1; then
        log_error "nftables not found. Installing..."
        opkg update >/dev/null 2>&1 && opkg install nftables >/dev/null 2>&1 || {
            log_error "Failed to install nftables. Exit."
            exit 1
        }
    fi
    
    # Проверка базовой таблицы fw4
    if ! nft list table inet fw4 >/dev/null 2>&1; then
        log_error "Table 'inet fw4' not found. Run main domain-routing script first."
        exit 1
    fi
    
    # Проверка базового set vpn_domains (индикатор корректной настройки)
    if ! nft list set inet fw4 vpn_domains >/dev/null 2>&1; then
        log_warn "Set 'vpn_domains' not found. Continuing, but verify base config."
    fi
    
    # Проверка таблицы маршрутизации vpn (99 vpn)
    if ! grep -q "^[[:space:]]*99[[:space:]]\+vpn" /etc/iproute2/rt_tables 2>/dev/null; then
        log_warn "Routing table 'vpn' (id 99) not found. Adding..."
        echo '99 vpn' >> /etc/iproute2/rt_tables
    fi
    
    # Проверка правила маркировки 0x1
    if ! uci show network 2>/dev/null | grep -q "mark='0x1'" 2>/dev/null; then
        log_warn "Rule with mark '0x1' not found. Adding..."
        uci add network rule >/dev/null 2>&1
        uci set network.@rule[-1].name='mark0x1' >/dev/null 2>&1
        uci set network.@rule[-1].mark='0x1' >/dev/null 2>&1
        uci set network.@rule[-1].priority='100' >/dev/null 2>&1
        uci set network.@rule[-1].lookup='vpn' >/dev/null 2>&1
        uci commit network >/dev/null 2>&1
    fi
    
    log_info "Prerequisites check completed."
    return 0
}

# =============================================================================
# Создание nftables sets для ip и subnet
# =============================================================================

create_nft_sets() {
    log_info "Creating nftables sets for ip and subnet lists..."
    
    # Создаём set для отдельных IP-адресов
    # Правильный синтаксис: без экранирования внутри команды, только в heredoc
    if nft list set inet fw4 vpn_ip >/dev/null 2>&1; then
        log_info "Set 'vpn_ip' already exists."
    else
        log_info "Creating set 'vpn_ip'..."
        # flags interval позволяет добавлять и одиночные IP, и подсети
        nft add set inet fw4 vpn_ip '{ type ipv4_addr; flags interval; }' 2>/dev/null || {
            log_error "Failed to create set 'vpn_ip'"
            return 1
        }
    fi
    
    # Создаём set для подсетей
    if nft list set inet fw4 vpn_subnets >/dev/null 2>&1; then
        log_info "Set 'vpn_subnets' already exists."
    else
        log_info "Creating set 'vpn_subnets'..."
        nft add set inet fw4 vpn_subnets '{ type ipv4_addr; flags interval; }' 2>/dev/null || {
            log_error "Failed to create set 'vpn_subnets'"
            return 1
        }
    fi
    
    log_info "nftables sets ready."
    return 0
}

# =============================================================================
# Валидация строки как IP или CIDR
# =============================================================================

is_valid_ip_or_cidr() {
    local line="$1"
    # Простая проверка: цифры, точки, слэш, дефисы (для диапазонов, если есть)
    # Поддерживает: 1.2.3.4, 1.2.3.0/24, 10.0.0.1-10.0.0.10 (если antifilter использует)
    echo "$line" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?(-([0-9]{1,3}\.){3}[0-9]{1,3})?$' 2>/dev/null
    return $?
}

# =============================================================================
# Загрузка и применение списков с antifilter.download
# =============================================================================

load_antifilter_list() {
    local LIST_NAME="$1"      # ip или subnet
    local SET_NAME="$2"       # vpn_ip или vpn_subnets
    local URL="https://antifilter.download/list/${LIST_NAME}.lst"
    local TMP_FILE="/tmp/lst/${LIST_NAME}.lst"
    
    mkdir -p /tmp/lst
    
    log_info "Downloading ${LIST_NAME}.lst from antifilter.download..."
    
    # Скачивание с таймаутом и проверкой кода возврата
    if ! curl -f -s --max-time 120 -o "$TMP_FILE" "$URL" 2>/dev/null; then
        log_error "Failed to download ${URL}"
        return 1
    fi
    
    if [ ! -s "$TMP_FILE" ]; then
        log_error "Downloaded file is empty: $TMP_FILE"
        return 1
    fi
    
    local COUNT=$(wc -l < "$TMP_FILE" | tr -d ' ')
    log_info "Downloaded ${LIST_NAME}.lst: ~${COUNT} lines"
    
    # Очистка существующего set перед загрузкой
    log_info "Flushing set '${SET_NAME}'..."
    nft flush set inet fw4 "${SET_NAME}" 2>/dev/null || true
    
    # Поэтапная загрузка элементов в set (пакетами по 50 для стабильности на слабых роутерах)
    log_info "Loading entries into set '${SET_NAME}'..."
    local BATCH=""
    local BATCH_COUNT=0
    local VALID_COUNT=0
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Пропуск пустых строк
        [ -z "$line" ] && continue
        # Пропуск комментариев
        case "$line" in \#*) continue ;; esac
        # Trim whitespace
        line=$(echo "$line" | tr -d '[:space:]')
        [ -z "$line" ] && continue
        
        # Валидация формата
        if ! is_valid_ip_or_cidr "$line"; then
            log_warn "Skipping invalid entry: $line"
            continue
        fi
        
        # Добавляем в пакет (через запятую)
        if [ -z "$BATCH" ]; then
            BATCH="$line"
        else
            BATCH="${BATCH}, ${line}"
        fi
        BATCH_COUNT=$((BATCH_COUNT + 1))
        VALID_COUNT=$((VALID_COUNT + 1))
        
        # Отправляем пакет каждые 50 элементов (меньше = стабильнее на слабом железе)
        if [ $BATCH_COUNT -ge 100 ]; then
            nft add element inet fw4 "${SET_NAME}" "{ ${BATCH} }" 2>/dev/null || true
            BATCH=""
            BATCH_COUNT=0
        fi
    done < "$TMP_FILE"
    
    # Отправка остатка
    if [ -n "$BATCH" ]; then
        nft add element inet fw4 "${SET_NAME}" "{ ${BATCH} }" 2>/dev/null || true
    fi
    
    log_info "Loaded ~${VALID_COUNT} valid entries into '${SET_NAME}'"
    return 0
}

# =============================================================================
# Создание firewall rules для маркировки трафика
# =============================================================================

create_firewall_rules() {
    log_info "Checking firewall rules for ip/subnet sets..."
    
    # Правило для vpn_ip
    # ВАЖНО: в OpenWrt fw4 параметр называется 'set', а не 'set_name'
    if uci show firewall 2>/dev/null | grep -q "@rule.*name='mark_vpn_ip'" 2>/dev/null; then
        log_info "Rule 'mark_vpn_ip' already exists."
    else
        log_info "Creating rule 'mark_vpn_ip'..."
        uci add firewall rule >/dev/null 2>&1
        uci set firewall.@rule[-1].name='mark_vpn_ip' >/dev/null 2>&1
        uci set firewall.@rule[-1].src='lan' >/dev/null 2>&1
        uci set firewall.@rule[-1].dest='*' >/dev/null 2>&1
        uci set firewall.@rule[-1].proto='all' >/dev/null 2>&1
        # Ключевое исправление: 'set' вместо 'set_name'
        uci set firewall.@rule[-1].set='vpn_ip' >/dev/null 2>&1
        uci set firewall.@rule[-1].set_mark='0x1' >/dev/null 2>&1
        uci set firewall.@rule[-1].target='MARK' >/dev/null 2>&1
        uci set firewall.@rule[-1].family='ipv4' >/dev/null 2>&1
        uci commit firewall >/dev/null 2>&1
    fi
    
    # Правило для vpn_subnets
    if uci show firewall 2>/dev/null | grep -q "@rule.*name='mark_vpn_subnets'" 2>/dev/null; then
        log_info "Rule 'mark_vpn_subnets' already exists."
    else
        log_info "Creating rule 'mark_vpn_subnets'..."
        uci add firewall rule >/dev/null 2>&1
        uci set firewall.@rule[-1].name='mark_vpn_subnets' >/dev/null 2>&1
        uci set firewall.@rule[-1].src='lan' >/dev/null 2>&1
        uci set firewall.@rule[-1].dest='*' >/dev/null 2>&1
        uci set firewall.@rule[-1].proto='all' >/dev/null 2>&1
        uci set firewall.@rule[-1].set='vpn_subnets' >/dev/null 2>&1
        uci set firewall.@rule[-1].set_mark='0x1' >/dev/null 2>&1
        uci set firewall.@rule[-1].target='MARK' >/dev/null 2>&1
        uci set firewall.@rule[-1].family='ipv4' >/dev/null 2>&1
        uci commit firewall >/dev/null 2>&1
    fi
    
    log_info "Firewall rules configured."
    return 0
}

# =============================================================================
# Настройка cron для автообновления списков
# =============================================================================

setup_cron_update() {
    log_info "Setting up cron job for auto-update (every 12 hours)..."
    
    local CRON_CMD="0 */12 * * * /etc/init.d/add-ip-subnet-routing start"
    local CRON_EXISTS=0
    
    # Безопасная проверка crontab (может вернуть ошибку, если crontab пуст)
    local CURRENT_CRON
    CURRENT_CRON=$(crontab -l 2>/dev/null) || CURRENT_CRON=""
    
    if echo "$CURRENT_CRON" | grep -q "add-ip-subnet-routing" 2>/dev/null; then
        log_info "Cron job already configured."
        return 0
    fi
    
    # Добавляем в crontab
    if [ -z "$CURRENT_CRON" ]; then
        echo "$CRON_CMD" | crontab - 2>/dev/null || {
            log_warn "Failed to set crontab. Add manually: $CRON_CMD"
            return 1
        }
    else
        (echo "$CURRENT_CRON"; echo "$CRON_CMD") | crontab - 2>/dev/null || {
            log_warn "Failed to update crontab. Add manually: $CRON_CMD"
            return 1
        }
    fi
    
    # Перезапускаем cron, если сервис доступен
    /etc/init.d/cron restart >/dev/null 2>&1 || true
    
    log_info "Cron job added: lists will update every 12 hours."
    return 0
}

# =============================================================================
# Основная функция
# =============================================================================

main() {
    echo "============================================================"
    echo "  Add IP/Subnet Routing to domain-routing-openwrt v1.1"
    echo "  Source: antifilter.download (list_ip + list_subnet)"
    echo "============================================================"
    echo ""
    
    check_prerequisites || exit 1
    create_nft_sets || exit 1
    
    # Загрузка списков (продолжаем, даже если один не загрузился)
    load_antifilter_list "ip" "vpn_ip" || log_warn "Failed to load list_ip"
    load_antifilter_list "subnet" "vpn_subnets" || log_warn "Failed to load list_subnet"
    
    create_firewall_rules || exit 1
    setup_cron_update || log_warn "Cron setup failed"
    
    # Применение изменений
    log_info "Applying firewall changes..."
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    
    echo ""
    echo "============================================================"
    log_info "Installation completed!"
    echo ""
    echo "Verification:"
    echo "  • Sets:        nft list sets | grep vpn_"
    echo "  • Entries:     nft list set inet fw4 vpn_ip | head -5"
    echo "  • Rules:       uci show firewall | grep mark_vpn"
    echo "  • Routing:     ip route show table vpn"
    echo ""
    echo "Manual update: /etc/init.d/add-ip-subnet-routing start"
    echo "============================================================"
}

# =============================================================================
# Init-script interface (/etc/rc.common compatible)
# =============================================================================

case "${1:-start}" in
    start)
        main
        ;;
    stop)
        log_info "Stopping: flushing ip/subnet sets..."
        nft flush set inet fw4 vpn_ip 2>/dev/null || true
        nft flush set inet fw4 vpn_subnets 2>/dev/null || true
        log_info "Sets cleared."
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