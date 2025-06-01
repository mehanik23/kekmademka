#!/bin/bash

# ANSI цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Константы
ZONE_DIR="/etc/bind/zones"
FORWARD_ZONE="au-team.irpo"
REVERSE_ZONE="100.168.192.in-addr.arpa"
FORWARD_FILE="$ZONE_DIR/au-team.db"
REVERSE_FILE="$ZONE_DIR/au-team_rev.db"

# Функция вывода сообщений
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
prompt() { echo -e "${YELLOW}$1${NC}"; }

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Ошибка: Запустите скрипт с правами root!${NC}"
  exit 1
fi

# Проверка установки bind9
check_bind() {
  if ! command -v named-checkconf &> /dev/null; then
    error "BIND9 не установлен. Установка..."
    apt update && apt install -y bind9
  fi
}

# Создание каталога для зон
create_zone_dir() {
  if [ ! -d "$ZONE_DIR" ]; then
    log "Создаю каталог для зон: $ZONE_DIR"
    mkdir -p "$ZONE_DIR"
  fi
}

# Создание файла прямой зоны
create_forward_zone() {
  cat > "$FORWARD_FILE" << EOF
\$TTL 86400
@       IN      SOA     ns1.$FORWARD_ZONE. admin.$FORWARD_ZONE. (
                        $(date +%Y%m%d01) ; Serial
                        3600           ; Refresh
                        1800           ; Retry
                        604800         ; Expire
                        86400 )         ; Minimum TTL

; Name servers
@       IN      NS      ns1.$FORWARD_ZONE.

; A records
ns1     IN      A       192.168.100.10
host1   IN      A       192.168.100.11
host2   IN      A       192.168.100.12
EOF
  log "Создан файл прямой зоны: $FORWARD_FILE"
}

# Создание файла обратной зоны
create_reverse_zone() {
  cat > "$REVERSE_FILE" << EOF
\$TTL 86400
@       IN      SOA     ns1.$FORWARD_ZONE. admin.$FORWARD_ZONE. (
                        $(date +%Y%m%d01) ; Serial
                        3600           ; Refresh
                        1800           ; Retry
                        604800         ; Expire
                        86400 )         ; Minimum TTL

; Name servers
@       IN      NS      ns1.$FORWARD_ZONE.

; PTR records
10      IN      PTR     ns1.$FORWARD_ZONE.
11      IN      PTR     host1.$FORWARD_ZONE.
12      IN      PTR     host2.$FORWARD_ZONE.
EOF
  log "Создан файл обратной зоны: $REVERSE_FILE"
}

# Обновление named.conf.local
update_named_config() {
  cat > "/etc/bind/named.conf.local" << EOF
// Прямая зона
zone "$FORWARD_ZONE" {
    type master;
    file "$FORWARD_FILE";
};

// Обратная зона
zone "$REVERSE_ZONE" {
    type master;
    file "$REVERSE_FILE";
};
EOF
  log "Обновлен конфиг /etc/bind/named.conf.local"
}

# Обновление named.conf.options
update_options_config() {
  cat > "/etc/bind/named.conf.options" << EOF
options {
    directory "/var/cache/bind";

    // Forwarding
    forwarders { 8.8.8.8; };

    // Listen on all interfaces
    listen-on { any; };
    listen-on-v6 { any; };

    // Allow queries from local network
    allow-query { any; };

    // Enable recursion for internal clients
    recursion no;

    dnssec-validation auto;
};
EOF
  log "Обновлен конфиг /etc/bind/named.conf.options"
}

# Проверка конфигурации
check_config() {
  log "Проверка конфигурации BIND..."

  if named-checkconf; then
    log "Конфигурация named.conf прошла проверку"
  else
    error "Ошибка в конфигурации named.conf!"
    return 1
  fi

  if named-checkzone "$FORWARD_ZONE" "$FORWARD_FILE"; then
    log "Прямая зона прошла проверку"
  else
    error "Ошибка в прямой зоне!"
    return 1
  fi

  if named-checkzone "$REVERSE_ZONE" "$REVERSE_FILE"; then
    log "Обратная зона прошла проверку"
  else
    error "Ошибка в обратной зоне!"
    return 1
  fi

  log "Все проверки пройдены успешно!"
}

# Перезапуск и включение автозапуска BIND
restart_and_enable_bind() {
  log "Перезапуск службы bind9..."
  systemctl restart bind9

  log "Включение автозапуска службы bind9..."
  systemctl enable bind9

  if systemctl is-active --quiet bind9; then
    log "Служба bind9 запущена и добавлена в автозагрузку"
  else
    error "Не удалось запустить службу bind9"
    return 1
  fi
}

# Основное меню
main_menu() {
  while true; do
    clear
    echo "========== DNS Настройка =========="
    echo "1. Настроить DNS зоны"
    echo "2. Проверить конфигурацию"
    echo "3. Выход"
    echo "=================================="
    
    read -p "Выберите пункт меню (1-3): " choice
    
    case $choice in
      1)
        check_bind
        create_zone_dir
        create_forward_zone
        create_reverse_zone
        update_named_config
        update_options_config
        restart_and_enable_bind
        ;;
      2)
        check_config
        ;;
      3)
        echo "Выход..."
        exit 0
        ;;
      *)
        error "Неверный выбор!"
        ;;
    esac
    
    read -p $'\nНажмите Enter для продолжения...'
  done
}

# Запуск меню
main_menu