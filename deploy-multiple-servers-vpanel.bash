#!/bin/bash

# Usage: sudo ./deploy_with_owner.sh example.com client_username

DOMAIN=$1
SYS_USER=$2 # The linux user (e.g., 'client')
BASE_PATH="/home/$SYS_USER/apps"
PROJECT_PATH="$BASE_PATH/$DOMAIN"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

# Validation
if [ -z "$DOMAIN" ] || [ -z "$SYS_USER" ]; then
    echo "Usage: sudo ./deploy.sh domain.com username"
    exit 1
fi

if [ ! -d "$PROJECT_PATH" ]; then
    echo "Error: Directory $PROJECT_PATH does not exist."
    exit 1
fi

# 1. Permission Fixes (Allow Nginx traversal)
# Nginx (www-data) needs to 'pass through' /home/client to get to static files
# We add www-data to the user's group
usermod -aG "$SYS_USER" www-data

# Ensure the home and apps folders have execute bit (traversal) for the group
chmod g+x "/home/$SYS_USER"
chmod g+x "/home/$SYS_USER/apps"
# Ensure project files are owned by the client
chown -R "$SYS_USER:$SYS_USER" "$PROJECT_PATH"

# 2. Install Dependencies (Standard)
apt-get update -qq
add-apt-repository -y ppa:ondrej/php &> /dev/null
apt-get update -qq
apt-get install -y -qq acl zip unzip

# 3. Detect PHP Version (Same logic as before)
if [ -f "$PROJECT_PATH/composer.json" ]; then
    RAW_VERSION=$(grep '"php":' "$PROJECT_PATH/composer.json" | head -n 1 | grep -oE '[0-9]+\.[0-9]+')
    MAJOR=$(echo "$RAW_VERSION" | cut -d. -f1)
    if [ -z "$MAJOR" ] || [ "$MAJOR" -lt 7 ]; then
        TARGET_PHP="7.4"
    else
        TARGET_PHP="$RAW_VERSION"
    fi
else
    TARGET_PHP="7.4"
fi

echo "Deploying using PHP $TARGET_PHP for User: $SYS_USER"

# Install PHP basics
apt-get install -y -qq "php$TARGET_PHP-fpm" "php$TARGET_PHP-cli" "php$TARGET_PHP-common" \
    "php$TARGET_PHP-mysql" "php$TARGET_PHP-xml" "php$TARGET_PHP-mbstring" "php$TARGET_PHP-curl"

# 4. CREATE CUSTOM FPM POOL (The Critical Fix)
# This forces PHP to run as 'client', not 'www-data'
POOL_CONF="/etc/php/$TARGET_PHP/fpm/pool.d/$DOMAIN.conf"
SOCKET_PATH="/run/php/php$TARGET_PHP-$DOMAIN-fpm.sock"

cat > "$POOL_CONF" <<EOF
[$DOMAIN]
user = $SYS_USER
group = $SYS_USER
listen = $SOCKET_PATH
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
chdir = /
EOF

# Restart FPM to load the new pool
systemctl restart "php$TARGET_PHP-fpm"

# 5. Run Composer (As the User)
cd "$PROJECT_PATH"
# We use 'sudo -u' to run composer as the client, preventing root-owned files
sudo -u "$SYS_USER" "/usr/bin/php$TARGET_PHP" /usr/local/bin/composer install --no-dev --optimize-autoloader --no-interaction

# 6. Nginx Config
WEB_ROOT="$PROJECT_PATH"
if [ -d "$PROJECT_PATH/public" ]; then WEB_ROOT="$PROJECT_PATH/public"; fi

CONFIG_FILE="$NGINX_AVAILABLE/$DOMAIN"

cat > "$CONFIG_FILE" <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_ROOT;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        # Point to the CUSTOM socket we defined in the pool above
        fastcgi_pass unix:$SOCKET_PATH;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 6M;
        add_header Cache-Control "public";
    }
}
EOF

ln -sf "$CONFIG_FILE" "$NGINX_ENABLED/$DOMAIN"
nginx -t && systemctl reload nginx

echo "Done. PHP running as user '$SYS_USER' on socket '$SOCKET_PATH'"