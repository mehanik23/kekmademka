#!/bin/bash

# ANSI цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Константы
FORWARD_ZONE="au-team.irpo"
REVERSE_ZONE="100.168.192.in-addr.arpa"
ZONE_DIR="/etc/bind/zones"
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

# Автоопределение IP сервера
detect_server_ip() {
  SERVER_IP=$(hostname -I | awk '{print $1}')
  if [[ -z "$SERVER_IP" ]]; then
    error "Не удалось определить IP-адрес сервера!"
    exit 1
  fi
  log "Обнаружен IP сервера: $SERVER_IP"
}

# Установка bind9 и dnsutils
install_packages() {
  log "Проверка установленных пакетов..."
  if ! command -v named-checkconf &> /dev/null; then
    log "Установка bind9 и dnsutils..."
    apt update && apt install -y bind9 dnsutils
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
@       IN      A       $SERVER_IP
ns1     IN      A       $SERVER_IP
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
    forwarders { 77.88.8.8; };

    // Listening ports and interfaces
    listen-on port 53 { any; };
    listen-on-v6 port 53 { none; };

    // Query access
    allow-query { any; };

    // Recursion settings
    recursion no;

    // DNSSEC
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

# Проверка доступности порта 53
check_dns_port() {
  log "Проверка, слушает ли BIND порт 53..."
  if ss -tuln | grep :53 >/dev/null; then
    log "Порт 53 открыт и прослушивается"
  else
    error "Порт 53 не прослушивается! Проверьте named.conf.options"
    return 1
  fi
}

# Разрешение порта 53 в брандмауэре
setup_firewall() {
  log "Разрешение порта 53 в брандмауэре..."
  ufw allow 53/tcp
  ufw allow 53/udp
  ufw reload
  log "Брандмауэр настроен"
}

# Установка DNS для всей системы
setup_resolv_conf() {
  log "Настройка /etc/resolv.conf для использования локального DNS..."
  echo "nameserver 127.0.0.1" > /etc/resolv.conf
}

# Тестирование через dig + ping
test_with_dig_and_ping() {
  prompt "Выполняется тестирование через 'dig' и 'ping'..."

  echo -e "\nЗапрос A-записи для au-team.irpo:"
  dig @127.0.0.1 au-team.irpo +short

  echo -e "\nПинг au-team.irpo..."
  ping -c 2 au-team.irpo

  echo -e "\nПинг 192.168.100.11..."
  ping -c 2 192.168.100.11
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
        detect_server_ip
        install_packages
        create_zone_dir
        create_forward_zone
        create_reverse_zone
        update_named_config
        update_options_config
        check_config
        setup_resolv_conf
        setup_firewall
        restart_and_enable_bind
        check_dns_port
        test_with_dig_and_ping
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
