#!/bin/bash

# Instalacja Flowise na Hetzner VPS - Skrypt Automatyczny
# Ten skrypt instaluje wszystko co potrzebne: Docker, Nginx, Flowise, SSL

set -e

echo "================================="
echo "INSTALACJA FLOWISE NA HETZNER VPS"
echo "================================="
echo ""

# Kolory dla outputu
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Funkcja do wyświetlania kolorowych wiadomości
print_green() {
    echo -e "${GREEN}$1${NC}"
}

print_yellow() {
    echo -e "${YELLOW}$1${NC}"
}

print_red() {
    echo -e "${RED}$1${NC}"
}

# Sprawdzanie czy skrypt jest uruchomiony jako root
if [[ $EUID -eq 0 ]]; then
   print_red "Ten skrypt nie powinien być uruchomiony jako root!"
   print_yellow "Zaloguj się jako zwykły użytkownik z uprawnieniami sudo"
   exit 1
fi

# Pobieranie informacji od użytkownika
print_yellow "Podaj domenę dla Flowise (np. flowise.twoja-domena.com):"
read -r DOMAIN

print_yellow "Podaj email dla certyfikatu SSL:"
read -r EMAIL

print_yellow "Podaj nazwę użytkownika dla Flowise:"
read -r FLOWISE_USER

print_yellow "Podaj hasło dla Flowise:"
read -s FLOWISE_PASS
echo ""

print_yellow "Podaj bezpieczny klucz szyfrowania (min. 32 znaki):"
read -s SECRET_KEY
echo ""

print_green "Rozpoczynam instalację..."

# 1. Aktualizacja systemu
print_green "1. Aktualizuję system..."
sudo apt update && sudo apt upgrade -y

# 2. Instalacja wymaganych pakietów
print_green "2. Instaluję wymagane pakiety..."
sudo apt install -y curl wget git ufw nginx certbot python3-certbot-nginx

# 3. Instalacja Docker
print_green "3. Instaluję Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
    rm get-docker.sh
    print_green "Docker zainstalowany!"
else
    print_yellow "Docker już jest zainstalowany"
fi

# 4. Instalacja Docker Compose
print_green "4. Instaluję Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    print_green "Docker Compose zainstalowany!"
else
    print_yellow "Docker Compose już jest zainstalowany"
fi

# 5. Konfiguracja firewall
print_green "5. Konfiguruję firewall..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# 6. Tworzenie katalogu projektu
print_green "6. Tworzę strukturę katalogów..."
mkdir -p ~/flowise
cd ~/flowise

# 7. Tworzenie pliku .env
print_green "7. Tworzę plik konfiguracyjny..."
cat > .env << EOF
PORT=3000
FLOWISE_USERNAME=$FLOWISE_USER
FLOWISE_PASSWORD=$FLOWISE_PASS
DATABASE_TYPE=sqlite
DATABASE_PATH=/root/.flowise
APIKEY_PATH=/root/.flowise
SECRETKEY_PATH=/root/.flowise
LOG_PATH=/root/.flowise/logs
FLOWISE_SECRETKEY_OVERWRITE=$SECRET_KEY
FLOWISE_FILE_SIZE_LIMIT=50mb
CORS_ORIGINS=*
IFRAME_ORIGINS=*
LOG_LEVEL=info
DEBUG=false
EOF

# 8. Tworzenie docker-compose.yml
print_green "8. Tworzę plik Docker Compose..."
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  flowise:
    image: flowiseai/flowise:latest
    container_name: flowise
    restart: unless-stopped
    environment:
      - PORT=3000
      - FLOWISE_USERNAME=\${FLOWISE_USERNAME}
      - FLOWISE_PASSWORD=\${FLOWISE_PASSWORD}
      - DATABASE_TYPE=\${DATABASE_TYPE}
      - DATABASE_PATH=\${DATABASE_PATH}
      - APIKEY_PATH=\${APIKEY_PATH}
      - SECRETKEY_PATH=\${SECRETKEY_PATH}
      - FLOWISE_SECRETKEY_OVERWRITE=\${FLOWISE_SECRETKEY_OVERWRITE}
      - LOG_PATH=\${LOG_PATH}
      - LOG_LEVEL=\${LOG_LEVEL}
      - DEBUG=\${DEBUG}
      - CORS_ORIGINS=\${CORS_ORIGINS}
      - IFRAME_ORIGINS=\${IFRAME_ORIGINS}
      - FLOWISE_FILE_SIZE_LIMIT=\${FLOWISE_FILE_SIZE_LIMIT}
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - flowise_data:/root/.flowise
    networks:
      - flowise_network
    command: /bin/sh -c "sleep 3; flowise start"

volumes:
  flowise_data:

networks:
  flowise_network:
    driver: bridge
EOF

# 9. Uruchomienie Flowise
print_green "9. Uruchamiam Flowise..."
# Może być potrzebne wylogowanie i zalogowanie dla grup dockera
if groups $USER | grep -q docker; then
    docker-compose up -d
else
    print_yellow "Uruchamiam z sudo (może być potrzebne ponowne zalogowanie)..."
    sudo docker-compose up -d
fi

# 10. Konfiguracja Nginx
print_green "10. Konfiguruję Nginx..."
sudo cat > /etc/nginx/sites-available/flowise << EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \\$host;
        proxy_set_header X-Real-IP \\$remote_addr;
        proxy_set_header X-Forwarded-For \\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\$scheme;
        proxy_cache_bypass \\$http_upgrade;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

# Aktywowanie konfiguracji Nginx
sudo ln -sf /etc/nginx/sites-available/flowise /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

# 11. Instalacja certyfikatu SSL
print_green "11. Instaluję certyfikat SSL..."
sudo certbot --nginx -d $DOMAIN --email $EMAIL --agree-tos --non-interactive --redirect

# 12. Konfiguracja automatycznego odnowienia certyfikatu
print_green "12. Konfiguruję automatyczne odnowienie SSL..."
echo "0 12 * * * /usr/bin/certbot renew --quiet" | sudo crontab -

# 13. Tworzenie skryptu backupu
print_green "13. Tworzę skrypt backupu..."
cat > backup.sh << 'EOF'
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$HOME/flowise-backups"
mkdir -p $BACKUP_DIR

echo "Rozpoczynam backup Flowise..."
docker run --rm -v flowise_data:/data -v $BACKUP_DIR:/backup ubuntu tar czf /backup/flowise_data_$DATE.tar.gz -C /data .
cp docker-compose.yml $BACKUP_DIR/docker-compose_$DATE.yml
cp .env $BACKUP_DIR/env_$DATE.txt

find $BACKUP_DIR -name "*.tar.gz" -mtime +7 -delete
find $BACKUP_DIR -name "*.yml" -mtime +7 -delete
find $BACKUP_DIR -name "*.txt" -mtime +7 -delete

echo "Backup completed: $BACKUP_DIR/flowise_data_$DATE.tar.gz"
EOF

chmod +x backup.sh

# 14. Ustawienie cotygodniowego backupu
print_green "14. Ustawiam cotygodniowy backup..."
(crontab -l 2>/dev/null; echo "0 2 * * 0 $HOME/flowise/backup.sh") | crontab -

print_green "================================="
print_green "INSTALACJA ZAKOŃCZONA POMYŚLNIE!"
print_green "================================="
echo ""
print_green "Flowise jest dostępny pod adresem: https://$DOMAIN"
print_green "Login: $FLOWISE_USER"
print_green "Hasło: [ukryte]"
echo ""
print_yellow "Przydatne komendy:"
echo "- Sprawdzenie statusu: docker-compose ps"
echo "- Restart Flowise: docker-compose restart"
echo "- Logi Flowise: docker-compose logs -f"
echo "- Zatrzymanie: docker-compose down"
echo "- Backup: ./backup.sh"
echo ""
print_yellow "Pliki konfiguracyjne znajdziesz w: $HOME/flowise"
print_yellow "Backupy będą tworzone w: $HOME/flowise-backups"
echo ""
print_green "Miłego korzystania z Flowise!"
