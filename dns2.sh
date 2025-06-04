#!/bin/bash

# ANSI цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Константы
FORWARD_ZONE="au-team.irpo"
REVERSE_ZONE_HQ="100.168.192.in-addr.arpa"
REVERSE_ZONE_BR="200.168.192.in-addr.arpa"
ZONE_DIR="/etc/bind/zones"
FORWARD_FILE="$ZONE_DIR/au-team.db"
REVERSE_FILE_HQ="$ZONE_DIR/au-team_hq_rev.db"
REVERSE_FILE_BR="$ZONE_DIR/au-team_br_rev.db"

# Фиксированный IP HQ-SRV
SERVER_IP="192.168.100.2"

# IP-адреса устройств (согласно схеме сети)
HQ_RTR_IP="192.168.100.1"      # Типичный адрес для роутера в подсети HQ
HQ_CLI_IP="192.168.100.64"     # Из схемы
BR_RTR_IP="192.168.200.1"      # Типичный адрес для роутера в подсети BR
BR_SRV_IP="192.168.200.2"      # Из схемы
ISP_HQ_IP="172.16.4.1"         # Предполагаемый адрес ISP со стороны HQ
ISP_BR_IP="172.16.5.1"         # Предполагаемый адрес ISP со стороны BR

# Функция вывода сообщений
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
prompt() { echo -e "${YELLOW}$1${NC}"; }

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Ошибка: Запустите скрипт с правами root!${NC}"
  exit 1
fi

# Проверка заполнения IP-адресов
check_ip_addresses() {
  log "IP-адреса загружены из конфигурации"
  log "HQ сеть: 192.168.100.0/24"
  log "BR сеть: 192.168.200.0/24"
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
@       IN      SOA     hq-srv.$FORWARD_ZONE. admin.$FORWARD_ZONE. (
                        $(date +%Y%m%d01) ; Serial
                        3600           ; Refresh
                        1800           ; Retry
                        604800         ; Expire
                        86400 )        ; Minimum TTL

; Name servers
@       IN      NS      hq-srv.$FORWARD_ZONE.

; A records согласно таблице 2
hq-srv    IN      A       $SERVER_IP
hq-rtr    IN      A       $HQ_RTR_IP
hq-cli    IN      A       $HQ_CLI_IP
br-rtr    IN      A       $BR_RTR_IP
br-srv    IN      A       $BR_SRV_IP
moodle    IN      A       $ISP_HQ_IP
wiki      IN      A       $ISP_BR_IP
EOF
  log "Создан файл прямой зоны: $FORWARD_FILE"
}

# Создание файла обратной зоны для подсети HQ
create_reverse_zone_hq() {
  # Извлекаем последний октет из IP-адресов
  HQ_SRV_LAST=$(echo $SERVER_IP | cut -d. -f4)
  HQ_RTR_LAST=$(echo $HQ_RTR_IP | cut -d. -f4)
  HQ_CLI_LAST=$(echo $HQ_CLI_IP | cut -d. -f4)
  
  cat > "$REVERSE_FILE_HQ" << EOF
\$TTL 86400
@       IN      SOA     hq-srv.$FORWARD_ZONE. admin.$FORWARD_ZONE. (
                        $(date +%Y%m%d01) ; Serial
                        3600           ; Refresh
                        1800           ; Retry
                        604800         ; Expire
                        86400 )        ; Minimum TTL

; Name servers
@       IN      NS      hq-srv.$FORWARD_ZONE.

; PTR records для HQ устройств (только те, что в таблице с типом PTR)
$HQ_SRV_LAST    IN      PTR     hq-srv.$FORWARD_ZONE.
$HQ_RTR_LAST    IN      PTR     hq-rtr.$FORWARD_ZONE.
$HQ_CLI_LAST    IN      PTR     hq-cli.$FORWARD_ZONE.
EOF
  log "Создан файл обратной зоны HQ: $REVERSE_FILE_HQ"
}

# Создание файла обратной зоны для подсети BR
create_reverse_zone_br() {
  # Извлекаем последний октет из IP-адресов
  BR_SRV_LAST=$(echo $BR_SRV_IP | cut -d. -f4)
  
  cat > "$REVERSE_FILE_BR" << EOF
\$TTL 86400
@       IN      SOA     hq-srv.$FORWARD_ZONE. admin.$FORWARD_ZONE. (
                        $(date +%Y%m%d01) ; Serial
                        3600           ; Refresh
                        1800           ; Retry
                        604800         ; Expire
                        86400 )        ; Minimum TTL

; Name servers
@       IN      NS      hq-srv.$FORWARD_ZONE.

; PTR records для BR устройств (только BR-SRV согласно таблице 2)
$BR_SRV_LAST    IN      PTR     br-srv.$FORWARD_ZONE.
EOF
  log "Создан файл обратной зоны BR: $REVERSE_FILE_BR"
}

# Обновление named.conf.local
update_named_config() {
  cat > "/etc/bind/named.conf.local" << EOF
// Прямая зона
zone "$FORWARD_ZONE" {
    type master;
    file "$FORWARD_FILE";
    allow-transfer { none; };
};

// Обратная зона для подсети HQ
zone "$REVERSE_ZONE_HQ" {
    type master;
    file "$REVERSE_FILE_HQ";
    allow-transfer { none; };
};

// Обратная зона для подсети BR
zone "$REVERSE_ZONE_BR" {
    type master;
    file "$REVERSE_FILE_BR";
    allow-transfer { none; };
};
EOF
  log "Обновлен конфиг /etc/bind/named.conf.local"
}

# Обновление named.conf.options
update_options_config() {
  cat > "/etc/bind/named.conf.options" << EOF
options {
    directory "/var/cache/bind";

    // Forwarding - используем общедоступный DNS сервер
    forwarders { 
        8.8.8.8;      // Google DNS
        77.88.8.8;    // Yandex DNS (резервный)
    };

    // Listening ports and interfaces
    listen-on port 53 { 127.0.0.1; $SERVER_IP; };
    listen-on-v6 port 53 { none; };

    // Query access - разрешаем запросы из локальных сетей
    allow-query { 
        localhost;
        192.168.0.0/16;    // Все локальные подсети
    };

    // Recursion settings - включаем рекурсию для локальных клиентов
    recursion yes;
    allow-recursion {
        localhost;
        192.168.0.0/16;
    };

    // DNSSEC
    dnssec-validation auto;

    // Дополнительные параметры безопасности
    version "not available";
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

  if named-checkzone "$REVERSE_ZONE_HQ" "$REVERSE_FILE_HQ"; then
    log "Обратная зона HQ прошла проверку"
  else
    error "Ошибка в обратной зоне HQ!"
    return 1
  fi

  if named-checkzone "$REVERSE_ZONE_BR" "$REVERSE_FILE_BR"; then
    log "Обратная зона BR прошла проверку"
  else
    error "Ошибка в обратной зоне BR!"
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
    error "Порт 53 не прослушивается! Проверьте логи: journalctl -u bind9"
    return 1
  fi
}

# Настройка firewall (если установлен)
setup_firewall() {
  if command -v ufw &> /dev/null; then
    log "Настройка UFW firewall..."
    ufw allow 53/tcp
    ufw allow 53/udp
    log "Firewall настроен"
  elif command -v firewall-cmd &> /dev/null; then
    log "Настройка firewalld..."
    firewall-cmd --permanent --add-service=dns
    firewall-cmd --reload
    log "Firewall настроен"
  else
    log "Firewall не обнаружен, пропускаем настройку"
  fi
}

# Установка DNS для сервера
setup_resolv_conf() {
  log "Настройка /etc/resolv.conf..."
  cat > /etc/resolv.conf << EOF
# DNS конфигурация для HQ-SRV
search $FORWARD_ZONE
nameserver 127.0.0.1
nameserver $SERVER_IP
EOF
  
  # Защита от перезаписи через DHCP
  if [ -f /etc/resolv.conf ]; then
    chattr +i /etc/resolv.conf
    log "Файл /etc/resolv.conf защищен от изменений"
  fi
}

# Тестирование DNS
test_dns() {
  prompt "\nВыполняется тестирование DNS..."
  
  echo -e "\n${GREEN}=== Тестирование прямого разрешения ===${NC}"
  for host in hq-srv hq-rtr hq-cli br-rtr br-srv moodle wiki; do
    echo -n "Проверка $host.$FORWARD_ZONE: "
    result=$(dig @127.0.0.1 $host.$FORWARD_ZONE +short)
    if [ -n "$result" ]; then
      echo -e "${GREEN}$result${NC}"
    else
      echo -e "${RED}НЕ РАЗРЕШЕНО${NC}"
    fi
  done
  
  echo -e "\n${GREEN}=== Тестирование обратного разрешения (PTR) ===${NC}"
  # Проверяем PTR для HQ устройств
  for ip in $SERVER_IP $HQ_RTR_IP $HQ_CLI_IP; do
    echo -n "Проверка PTR для $ip: "
    result=$(dig @127.0.0.1 -x $ip +short)
    if [ -n "$result" ]; then
      echo -e "${GREEN}$result${NC}"
    else
      echo -e "${RED}НЕ РАЗРЕШЕНО${NC}"
    fi
  done
  
  # Проверяем PTR для BR-SRV
  echo -n "Проверка PTR для $BR_SRV_IP: "
  result=$(dig @127.0.0.1 -x $BR_SRV_IP +short)
  if [ -n "$result" ]; then
    echo -e "${GREEN}$result${NC}"
  else
    echo -e "${RED}НЕ РАЗРЕШЕНО${NC}"
  fi
  
  echo -e "\n${GREEN}=== Проверка рекурсии (внешний запрос) ===${NC}"
  echo -n "Проверка ya.ru: "
  result=$(dig @127.0.0.1 ya.ru +short)
  if [ -n "$result" ]; then
    echo -e "${GREEN}$result${NC}"
  else
    echo -e "${RED}Рекурсия не работает${NC}"
  fi
}

# Показать текущую конфигурацию
show_config() {
  echo -e "\n${GREEN}=== Текущая конфигурация DNS ===${NC}"
  echo "DNS сервер: $SERVER_IP"
  echo "Домен: $FORWARD_ZONE"
  echo ""
  echo "Настроенные записи:"
  echo "  hq-srv.$FORWARD_ZONE -> $SERVER_IP (A, PTR)"
  echo "  hq-rtr.$FORWARD_ZONE -> $HQ_RTR_IP (A, PTR)"
  echo "  hq-cli.$FORWARD_ZONE -> $HQ_CLI_IP (A, PTR)"
  echo "  br-rtr.$FORWARD_ZONE -> $BR_RTR_IP (A)"
  echo "  br-srv.$FORWARD_ZONE -> $BR_SRV_IP (A, PTR)"
  echo "  moodle.$FORWARD_ZONE -> $ISP_HQ_IP (A)"
  echo "  wiki.$FORWARD_ZONE -> $ISP_BR_IP (A)"
}

# Основное меню
main_menu() {
  while true; do
    clear
    echo "========== DNS Настройка HQ-SRV =========="
    echo "1. Полная настройка DNS сервера"
    echo "2. Проверить конфигурацию"
    echo "3. Тестировать DNS"
    echo "4. Показать текущую конфигурацию"
    echo "5. Перезапустить BIND"
    echo "6. Выход"
    echo "=========================================="
    
    read -p "Выберите пункт меню (1-6): " choice
    
    case $choice in
      1)
        check_ip_addresses
        install_packages
        create_zone_dir
        create_forward_zone
        create_reverse_zone_hq
        create_reverse_zone_br
        update_named_config
        update_options_config
        check_config
        if [ $? -eq 0 ]; then
          setup_resolv_conf
          setup_firewall
          restart_and_enable_bind
          check_dns_port
          test_dns
        fi
        ;;
      2)
        check_config
        ;;
      3)
        test_dns
        ;;
      4)
        show_config
        ;;
      5)
        restart_and_enable_bind
        ;;
      6)
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
echo -e "${YELLOW}DNS Setup Script для HQ-SRV${NC}"
echo -e "${YELLOW}================================${NC}"
main_menu
