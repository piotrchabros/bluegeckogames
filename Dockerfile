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

# Configure Apache: allow .htaccess overrides in /var/www/
RUN sed -i '/<Directory \/var\/www\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf

# Copy built WordPress from builder stage
COPY --from=builder /app/build/ /var/www/html/

# Grunt excludes index.php from the build output. Create the WordPress
# front controller directly (same content as src/_index.php).
RUN printf '%s\n' \
  '<?php' \
  'define( "WP_USE_THEMES", true );' \
  'require __DIR__ . "/wp-blog-header.php";' \
  > /var/www/html/index.php

# Simple healthcheck endpoint that does not load WordPress
RUN echo '<?php http_response_code(200); echo "ok";' > /var/www/html/healthz.php

# Generate wp-config.php from environment variables at runtime
RUN cat > /var/www/html/wp-config.php <<'WPCONFIG'
<?php
define('DB_NAME',     getenv('WORDPRESS_DB_NAME')     ?: 'wordpress');
define('DB_USER',     getenv('WORDPRESS_DB_USER')     ?: 'root');
define('DB_PASSWORD', getenv('WORDPRESS_DB_PASSWORD') ?: '');
define('DB_HOST',     getenv('WORDPRESS_DB_HOST')     ?: 'localhost');
define('DB_CHARSET',  'utf8mb4');
define('DB_COLLATE',  '');

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

if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}

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

# Set proper ownership
RUN chown -R www-data:www-data /var/www/html

# Entrypoint: handle Railway PORT, then start Apache
RUN cat > /usr/local/bin/wordpress-entrypoint.sh <<'ENTRY'
#!/bin/sh
PORT="${PORT:-80}"
echo "Starting WordPress on port ${PORT}..."

# Update Apache to listen on Railway's assigned port
sed -i "s/Listen 80/Listen ${PORT}/g" /etc/apache2/ports.conf
sed -i "s/:80>/:${PORT}>/g" /etc/apache2/sites-enabled/000-default.conf

exec apache2-foreground
ENTRY
RUN chmod +x /usr/local/bin/wordpress-entrypoint.sh

EXPOSE 80
CMD ["wordpress-entrypoint.sh"]