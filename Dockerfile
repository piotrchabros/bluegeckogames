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

# Grunt excludes index.php and _index.php from the build, then re-adds them
# via a files-object mapping that doesn't always work. Create them directly.
RUN printf '%s\n' \
  '<?php' \
  'define( "WP_USE_THEMES", true );' \
  'require __DIR__ . "/wp-blog-header.php";' \
  > /var/www/html/index.php

# Debug: list root of document root so we can see what the build produced
RUN ls -la /var/www/html/ && echo "---wp-admin---" && ls /var/www/html/wp-admin/ | head -20 || true

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

# Set proper ownership
RUN chown -R www-data:www-data /var/www/html

# Fix MPM at startup: ensure only mpm_prefork is loaded (required for mod_php)
RUN printf '#!/bin/sh\nrm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*\nln -sf /etc/apache2/mods-available/mpm_prefork.load /etc/apache2/mods-enabled/mpm_prefork.load\nln -sf /etc/apache2/mods-available/mpm_prefork.conf /etc/apache2/mods-enabled/mpm_prefork.conf\nexec apache2-foreground\n' > /usr/local/bin/wordpress-entrypoint.sh && \
    chmod +x /usr/local/bin/wordpress-entrypoint.sh

EXPOSE 80
CMD ["wordpress-entrypoint.sh"]
