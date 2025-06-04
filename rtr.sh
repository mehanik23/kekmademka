#!/bin/bash

# Проверка root
[ "$EUID" -ne 0 ] && { echo "Запустите с root"; exit 1; }

# Константы
WAN="ens3"
LAN="ens4"
ROLE=$([ -t 0 ] && select r in "HQ-RTR" "BR-RTR"; do echo $r; break; done || echo "HQ-RTR")

# Основные настройки
setup_gre() {
  ip link del gre0 2>/dev/null
  modprobe ip_gre
  
  # Переменные по ролям
  [ "$ROLE" = "HQ-RTR" ] && {
    LOCAL_IP=$(ip -4 addr show $WAN | grep -oP 'inet \K[\d.]+')
    REMOTE_IP="172.16.5.2"
    TUNNEL_IP="10.0.0.1/30"
    ROUTE="192.168.200.0/24 via 10.0.0.2"
  } || {
    LOCAL_IP=$(ip -4 addr show $WAN | grep -oP 'inet \K[\d.]+')
    REMOTE_IP="172.16.4.2"
    TUNNEL_IP="10.0.0.2/30"
    ROUTE="192.168.100.0/24 via 10.0.0.1"
  }

  # Создание туннеля
  cat >/etc/systemd/network/25-gre0.netdev <<EOL
[NetDev]
Name=gre0
Kind=gre
[Tunnel]
Local=$LOCAL_IP
Remote=$REMOTE_IP
EOL

  cat >/etc/systemd/network/25-gre0.network <<EOL
[Match]
Name=gre0
[Network]
Address=$TUNNEL_IP
[Route]
Destination=$(echo $ROUTE | awk '{print $1}')
Gateway=$(echo $ROUTE | awk '{print $3}')
EOL

  systemctl restart systemd-networkd
  sleep 2
  ip route add $ROUTE
}

# Настройка OSPF
setup_ospf() {
  apt update && apt install -y frr
  sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
  systemctl restart frr

  [ "$ROLE" = "HQ-RTR" ] && cat >/etc/frr/frr.conf <<EOL
hostname HQ-RTR
router ospf
 network 192.168.100.0/24 area 0
 network 10.0.0.0/30 area 0
EOL
  || cat >/etc/frr/frr.conf <<EOL
hostname BR-RTR
router ospf
 network 192.168.200.0/24 area 0
 network 10.0.0.0/30 area 0
EOL

  systemctl restart frr
}

# Базовый файрвол
setup_firewall() {
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
  sysctl -p
  iptables -A INPUT -p gre -j ACCEPT
  iptables -A INPUT -p ospf -j ACCEPT
  iptables-save > /etc/iptables/rules.v4
}

# Выполнение
setup_gre && setup_ospf && setup_firewall
echo "Настройка завершена"
