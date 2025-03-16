#!/bin/bash

# Farben für die Ausgabe definieren (Rot statt Grün)
RED='\033[0;31m'
NC='\033[0m' # No Color

# diabolo511 ASCII-Art
echo -e "${RED}
  _____  _               _         _       
 |  __ \(_)             | |       | |      
 | |  | |  __ _  ___   __| | ___   | | ___ 
 | |  | | / _\` |/ __| / _\` |/ _ \  | |/ _ \\
 | |__| || (_| |\__ \| (_| | (_) | | |  __/
 |_____/  \__,_||___/ \__,_|\___/  |_|\___|
                 511
${NC}"
echo -e "${RED}Beginn der Installation von Pi-hole, nginx, DuckDNS Plugin und WireGuard...${NC}"

# Update und Upgrade des Systems
echo -e "${RED}System wird aktualisiert...${NC}"
sudo apt-get update && sudo apt-get upgrade -y

# Installation von Pi-hole
echo -e "${RED}Pi-hole wird installiert...${NC}"
curl -sSL https://install.pi-hole.net | bash

# Pi-hole auf Port 8080 konfigurieren
echo -e "${RED}Konfiguration von Pi-hole auf Port 8080...${NC}"
sudo sed -i 's/80/8080/g' /etc/lighttpd/lighttpd.conf
sudo systemctl restart lighttpd

# Installation von nginx
echo -e "${RED}nginx wird installiert...${NC}"
sudo apt-get install -y nginx

# Benutzer nach der Domain und E-Mail-Adresse fragen
echo -e "${RED}Bitte geben Sie die Domain für das Pi-hole Webinterface an (z.B. example.com):${NC}"
read DOMAIN
echo -e "${RED}Bitte geben Sie Ihre E-Mail-Adresse für Let's Encrypt an:${NC}"
read EMAIL

# Konfiguration für nginx erstellen (Reverse-Proxy zu Pi-hole auf Port 8080)
echo -e "${RED}Konfiguration von nginx für die Domain ${DOMAIN}...${NC}"
sudo bash -c "cat <<EOT > /etc/nginx/sites-available/${DOMAIN}
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOT"

# Symlink zur Aktivierung der nginx-Konfiguration
sudo ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/
sudo systemctl restart nginx

# Let's Encrypt-Zertifikat für die Domain beantragen
echo -e "${RED}Let's Encrypt-Zertifikat für ${DOMAIN} wird beantragt...${NC}"
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d ${DOMAIN} --email ${EMAIL} --agree-tos --non-interactive

# -----------------------------------------------------------
# Installation des DuckDNS Plugins (für dynamisches DNS-Update)
# -----------------------------------------------------------
echo -e "${RED}Einrichtung des DuckDNS Plugins...${NC}"
echo -e "${RED}Bitte geben Sie Ihre DuckDNS-Domain ein (ohne .duckdns.org):${NC}"
read DUCKDNS_DOMAIN
echo -e "${RED}Bitte geben Sie Ihren DuckDNS Token ein:${NC}"
read DUCKDNS_TOKEN

echo -e "${RED}Erstelle die DuckDNS-Konfigurationsdatei...${NC}"
sudo bash -c "cat <<EOF > /etc/letsencrypt/duckdns.ini
dns_duckdns_token=${DUCKDNS_TOKEN}
duckdns_domain=${DUCKDNS_DOMAIN}
EOF"
sudo chmod 600 /etc/letsencrypt/duckdns.ini

echo -e "${RED}Erstelle das DuckDNS Update-Skript...${NC}"
sudo mkdir -p /opt/duckdns
sudo bash -c "cat <<'EOF' > /opt/duckdns/duck.sh
#!/bin/bash
# Dieses Skript aktualisiert den DuckDNS DNS-Eintrag
source /etc/letsencrypt/duckdns.ini
if [ -z \"\$duckdns_domain\" ] || [ -z \"\$dns_duckdns_token\" ]; then
    echo \"DuckDNS domain oder Token nicht gesetzt!\"
    exit 1
fi
curl -s \"https://www.duckdns.org/update?domains=\${duckdns_domain}&token=\${dns_duckdns_token}&ip=\"
EOF"
sudo chmod +x /opt/duckdns/duck.sh

echo -e "${RED}Erstelle den systemd-Service und Timer für DuckDNS...${NC}"
sudo bash -c "cat <<'EOF' > /etc/systemd/system/duckdns.service
[Unit]
Description=DuckDNS Update Service

[Service]
Type=oneshot
ExecStart=/opt/duckdns/duck.sh
EOF"

sudo bash -c "cat <<'EOF' > /etc/systemd/system/duckdns.timer
[Unit]
Description=Timer for DuckDNS Update every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable --now duckdns.timer
echo -e "${RED}DuckDNS Plugin installiert und aktiviert.${NC}"

# -----------------------------------------------------------
# Installation von WireGuard
# -----------------------------------------------------------
echo -e "${RED}WireGuard wird installiert...${NC}"
sudo apt-get install -y wireguard qrencode

# WireGuard Verzeichnis erstellen und in das Verzeichnis wechseln
sudo mkdir -p /etc/wireguard
cd /etc/wireguard

# WireGuard-Schlüssel generieren
echo -e "${RED}WireGuard-Schlüssel werden generiert...${NC}"
umask 077
wg genkey | tee server_privatekey | wg pubkey > server_publickey

SERVER_PRIVATE_KEY=$(cat server_privatekey)
SERVER_PUBLIC_KEY=$(cat server_publickey)

# Client-Schlüssel generieren
wg genkey | tee client_privatekey | wg pubkey > client_publickey

CLIENT_PRIVATE_KEY=$(cat client_privatekey)
CLIENT_PUBLIC_KEY=$(cat client_publickey)

# Server-IP ermitteln
SERVER_IP=$(curl -s ifconfig.me)

# Server-Konfiguration erstellen
SERVER_CONF="[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIVATE_KEY
DNS = 127.0.0.1

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32
"
echo "$SERVER_CONF" | sudo tee /etc/wireguard/wg0.conf

# Client-Konfiguration erstellen
CLIENT_CONF="[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.0.0.2/24
DNS = 10.0.0.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = ${SERVER_IP}:51820
AllowedIPs = 0.0.0.0/0
"
echo "$CLIENT_CONF" | sudo tee /etc/wireguard/client.conf

# IP-Forwarding aktivieren
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -p

# iptables konfigurieren, um den Verkehr über das VPN zu leiten
echo -e "${RED}Konfiguration von iptables...${NC}"
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT
sudo sh -c "iptables-save > /etc/iptables/rules.v4"

# WireGuard-Dienst starten und aktivieren
sudo systemctl start wg-quick@wg0
sudo systemctl enable wg-quick@wg0

# QR-Code für die Client-Konfiguration generieren und anzeigen
echo -e "${RED}Client-Konfiguration wird erstellt und QR-Code generiert...${NC}"
qrencode -t ansiutf8 < /etc/wireguard/client.conf

echo -e "${RED}Installation abgeschlossen! Verbinden Sie sich mit Ihrem VPN, um werbefrei zu surfen.${NC}"

qrencode -t ansiutf8 < /etc/wireguard/client.conf

echo -e "${GREEN}Installation abgeschlossen! Verbinden Sie sich mit Ihrem VPN, um werbefrei zu surfen.${NC}"
