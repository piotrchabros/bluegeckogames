# Stage 1: Build WordPress assets (JS, CSS, blocks)
FROM node:20-bookworm AS builder

WORKDIR /app
COPY package.json package-lock.json .npmrc ./
RUN npm ci --ignore-scripts

COPY . .
RUN npm rebuild && npm run postinstall && npx grunt build

# Stage 2: Production PHP + Apache
FROM php:8.2-apache

# Install PHP extensions required by WordPress
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libzip-dev \
        libicu-dev \
        libonig-dev \
    ; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j$(nproc) \
        gd \
        mysqli \
        opcache \
        zip \
        intl \
        mbstring \
        exif \
    ; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*

# Enable mod_rewrite for WordPress permalinks
RUN a2enmod rewrite

# Set recommended PHP settings for WordPress
RUN { \
    echo 'upload_max_filesize = 64M'; \
    echo 'post_max_size = 64M'; \
    echo 'memory_limit = 256M'; \
    echo 'max_execution_time = 300'; \
    echo 'max_input_vars = 3000'; \
} > /usr/local/etc/php/conf.d/wordpress.ini

# Set recommended opcache settings
RUN { \
    echo 'opcache.memory_consumption=128'; \
    echo 'opcache.interned_strings_buffer=8'; \
    echo 'opcache.max_accelerated_files=4000'; \
    echo 'opcache.revalidate_freq=2'; \
} > /usr/local/etc/php/conf.d/opcache-recommended.ini

# Configure Apache to allow .htaccess overrides
RUN sed -i '/<Directory \/var\/www\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf

# Copy built WordPress from builder stage
COPY --from=builder /app/build/ /var/www/html/

# Generate wp-config.php (can't rely on git since .gitignore excludes it)
RUN cat > /var/www/html/wp-config.php <<'WPCONFIG'
<?php
// Database settings - reads WORDPRESS_DB_* env vars from Railway
define('DB_NAME',     getenv('WORDPRESS_DB_NAME')     ?: 'wordpress');
define('DB_USER',     getenv('WORDPRESS_DB_USER')     ?: 'root');
define('DB_PASSWORD', getenv('WORDPRESS_DB_PASSWORD') ?: '');
define('DB_HOST',     getenv('WORDPRESS_DB_HOST')     ?: 'localhost');
define('DB_CHARSET',  'utf8mb4');
define('DB_COLLATE',  '');

// Authentication keys and salts
define('AUTH_KEY',         getenv('WORDPRESS_AUTH_KEY')         ?: 'put-unique-phrase-here');
define('SECURE_AUTH_KEY',  getenv('WORDPRESS_SECURE_AUTH_KEY')  ?: 'put-unique-phrase-here');
define('LOGGED_IN_KEY',    getenv('WORDPRESS_LOGGED_IN_KEY')    ?: 'put-unique-phrase-here');
define('NONCE_KEY',        getenv('WORDPRESS_NONCE_KEY')        ?: 'put-unique-phrase-here');
define('AUTH_SALT',        getenv('WORDPRESS_AUTH_SALT')        ?: 'put-unique-phrase-here');
define('SECURE_AUTH_SALT', getenv('WORDPRESS_SECURE_AUTH_SALT') ?: 'put-unique-phrase-here');
define('LOGGED_IN_SALT',   getenv('WORDPRESS_LOGGED_IN_SALT')  ?: 'put-unique-phrase-here');
define('NONCE_SALT',       getenv('WORDPRESS_NONCE_SALT')       ?: 'put-unique-phrase-here');

$table_prefix = getenv('WORDPRESS_TABLE_PREFIX') ?: 'wp_';

define('WP_DEBUG', filter_var(getenv('WP_DEBUG') ?: 'false', FILTER_VALIDATE_BOOLEAN));

// Force HTTPS behind Railway's proxy
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}

// Set site URL from Railway's domain
if (getenv('RAILWAY_PUBLIC_DOMAIN')) {
    define('DOMAIN_CURRENT_SITE', getenv('RAILWAY_PUBLIC_DOMAIN'));
    define('WP_HOME', 'https://' . getenv('RAILWAY_PUBLIC_DOMAIN'));
    define('WP_SITEURL', 'https://' . getenv('RAILWAY_PUBLIC_DOMAIN'));
}

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}

require_once ABSPATH . 'wp-settings.php';
WPCONFIG

# Install WP-CLI for automated WordPress installation
RUN curl -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp

# Install MySQL client for DB readiness check
RUN apt-get update && apt-get install -y --no-install-recommends default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

# Set proper ownership
RUN chown -R www-data:www-data /var/www/html

# Create a lightweight healthcheck endpoint (does not load WordPress)
RUN echo '<?php http_response_code(200); echo "ok";' > /var/www/html/healthz.php \
    && chown www-data:www-data /var/www/html/healthz.php

# Entrypoint: configure Apache port, start Apache immediately, then set up WP in background
RUN cat > /usr/local/bin/wp-setup-background.sh <<'BGSCRIPT'
#!/bin/sh
# Background script: wait for DB and install WordPress
# This runs AFTER Apache is already serving requests

sleep 5  # Give Apache a moment to fully start

DB_HOST=$(php -r "echo getenv('WORDPRESS_DB_HOST') ?: 'localhost';")
DB_USER=$(php -r "echo getenv('WORDPRESS_DB_USER') ?: 'root';")
DB_PASS=$(php -r "echo getenv('WORDPRESS_DB_PASSWORD') ?: '';")

echo "[wp-setup] Waiting for database at $DB_HOST..."
ATTEMPTS=0
MAX_ATTEMPTS=30
until mysqladmin ping -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" --silent 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
        echo "[wp-setup] ERROR: Database not reachable after ${MAX_ATTEMPTS} attempts. Giving up."
        exit 1
    fi
    echo "[wp-setup]   DB not ready (attempt $ATTEMPTS/$MAX_ATTEMPTS)..."
    sleep 2
done
echo "[wp-setup] Database is reachable."

if ! su -s /bin/sh www-data -c "wp core is-installed --path=/var/www/html" 2>/dev/null; then
    echo "[wp-setup] WordPress not installed. Running auto-install..."
    SITE_URL="${WP_HOME:-http://localhost}"
    ADMIN_USER="${WORDPRESS_ADMIN_USER:-admin}"
    ADMIN_PASS="${WORDPRESS_ADMIN_PASSWORD:-changeme}"
    ADMIN_EMAIL="${WORDPRESS_ADMIN_EMAIL:-admin@example.com}"
    SITE_TITLE="${WORDPRESS_SITE_TITLE:-Blue Gecko Games}"

    su -s /bin/sh www-data -c "wp core install \
        --path=/var/www/html \
        --url='${SITE_URL}' \
        --title='${SITE_TITLE}' \
        --admin_user='${ADMIN_USER}' \
        --admin_password='${ADMIN_PASS}' \
        --admin_email='${ADMIN_EMAIL}' \
        --skip-email" \
    && echo "[wp-setup] WordPress installed successfully." \
    || echo "[wp-setup] WARNING: WordPress auto-install failed."
else
    echo "[wp-setup] WordPress is already installed."
fi
BGSCRIPT
RUN chmod +x /usr/local/bin/wp-setup-background.sh

RUN cat > /usr/local/bin/wordpress-entrypoint.sh <<'ENTRY'
#!/bin/sh
set -e

# Railway sets PORT; default to 80 if unset
PORT="${PORT:-80}"
echo "Configuring Apache to listen on port ${PORT}..."

# Make Apache listen on the correct port
sed -i "s/Listen 80/Listen ${PORT}/" /etc/apache2/ports.conf
sed -i "s/<VirtualHost \*:80>/<VirtualHost *:${PORT}>/" /etc/apache2/sites-enabled/000-default.conf

# Ensure only mpm_prefork is loaded (required for mod_php)
rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*
ln -sf /etc/apache2/mods-available/mpm_prefork.load /etc/apache2/mods-enabled/mpm_prefork.load
ln -sf /etc/apache2/mods-available/mpm_prefork.conf /etc/apache2/mods-enabled/mpm_prefork.conf

# Launch DB wait + WP install in the background so Apache starts immediately
/usr/local/bin/wp-setup-background.sh &

echo "Starting Apache on port ${PORT}..."
exec apache2-foreground
ENTRY
RUN chmod +x /usr/local/bin/wordpress-entrypoint.sh

EXPOSE 80
CMD ["wordpress-entrypoint.sh"]
