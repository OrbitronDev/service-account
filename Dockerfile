# The different stages of this Dockerfile are meant to be built into separate images
# https://docs.docker.com/develop/develop-images/multistage-build/#stop-at-a-specific-build-stage
# https://docs.docker.com/compose/compose-file/#target

# https://docs.docker.com/engine/reference/builder/#understand-how-arg-and-from-interact
ARG PHP_VERSION=7.4
ARG NGINX_VERSION=1.19

# ---------
# PHP stage
# ---------
FROM php:${PHP_VERSION}-fpm-alpine AS php

WORKDIR /app

# Setup Alpine
# hadolint ignore=DL3018
RUN set -eux; \
	\
    apk update; \
    apk add --no-cache \
    	bash \
        bash-completion \
        # Required by symfony
        git \
        # Required to check connectivity
        mysql-client \
        # Required for healthcheck
        fcgi; \
    \
    # Custom bash config
    { \
        echo 'source /etc/profile.d/bash_completion.sh'; \
        # <green> user@host <normal> : <blue> dir <normal> $#
        echo 'export PS1="🐳 \e[38;5;10m\u@\h\e[0m:\e[38;5;12m\w\e[0m\\$ "'; \
    } >"$HOME/.bashrc"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Build PHP
# hadolint ignore=DL3018,SC2086
RUN set -eux; \
    \
    # Get all php requirements
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        # Required for gd
    	freetype-dev \
    	libjpeg-turbo-dev \
    	libpng-dev \
        # Required for intl
    	icu-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg >/dev/null; \
    docker-php-ext-install -j "$(nproc)" \
    	gd \
    	intl \
    	opcache \
    	pdo_mysql \
    	>/dev/null; \
    pecl install apcu >/dev/null; \
    pecl clear-cache; \
    docker-php-ext-enable \
        apcu \
        opcache; \
    \
    # Find packages to keep, so we can safely delete dev packages
    RUN_DEPS="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions | \
            tr ',' '\n' | \
            sort -u | \
            awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .phpexts-rundeps $RUN_DEPS; \
	\
    # Remove building tools for smaller container size
    apk del .build-deps

# Setup PHP
RUN set -eux; \
    \
    # Set default php configuration
    ln -s "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"; \
    \
    # Install composer
    curl -fsSL -o composer-setup.php https://getcomposer.org/installer; \
    EXPECTED_CHECKSUM="$(curl -fsSL https://composer.github.io/installer.sig)"; \
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"; \
    \
    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then \
        >&2 echo 'ERROR: Invalid installer checksum'; \
        rm composer-setup.php; \
        exit 1; \
    fi; \
    \
    php composer-setup.php --quiet; \
    rm composer-setup.php; \
    mv composer.phar /usr/bin/composer; \
    \
    # Install Symfony CLI
    curl -fsSL -o symfony-setup.sh https://get.symfony.com/cli/installer; \
    chmod +x symfony-setup.sh; \
    ./symfony-setup.sh --install-dir /usr/local/bin; \
    rm symfony-setup.sh

# Prevent the reinstallation of vendors at every changes in the source code
COPY composer.json composer.lock symfony.lock ./
RUN set -eux; \
	composer install --prefer-dist --no-dev --no-interaction --no-plugins --no-scripts --no-progress --no-suggest --optimize-autoloader; \
    composer clear-cache

# Do not use .env files in production
COPY .env ./
RUN composer dump-env prod; \
	rm .env

# Setup application
COPY bin ./bin
COPY config ./config
COPY migrations ./migrations
COPY public ./public
COPY src ./src
COPY templates ./templates
COPY translations ./translations
RUN set -eux; \
    \
    # Fix permission
    chown www-data:www-data -R .; \
    find . -type d -exec chmod 755 {} \;; \
    find . -type f -exec chmod 644 {} \;; \
    chmod +x bin/*; \
	\
    # Prepare Symfony
    ./bin/console cache:warmup --env=prod

# https://github.com/renatomefi/php-fpm-healthcheck
RUN curl -fsSL -o /usr/local/bin/php-fpm-healthcheck https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/master/php-fpm-healthcheck; \
    chmod +x /usr/local/bin/php-fpm-healthcheck; \
    echo 'pm.status_path = /status' >> /usr/local/etc/php-fpm.d/zz-docker.conf
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 CMD php-fpm-healthcheck || exit 1

COPY docker/php/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
ENTRYPOINT ["docker-entrypoint"]
CMD ["php-fpm"]

# -----------
# Nginx stage
# -----------
# Depends on the "php" stage above
FROM nginx:${NGINX_VERSION}-alpine AS nginx

WORKDIR /app/public

# Setup Alpine
# hadolint ignore=DL3018
RUN set -eux; \
    \
    apk update; \
    apk add --no-cache \
        bash \
        bash-completion \
        openssl; \
    \
    # Custom bash config
    { \
        echo 'source /etc/profile.d/bash_completion.sh'; \
        # <green> user@host <normal> : <blue> dir <normal> $#
        echo 'export PS1="🐳 \e[38;5;10m\u@\h\e[0m:\e[38;5;12m\w\e[0m\\$ "'; \
    } >"$HOME/.bashrc"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Setup Nginx
COPY --from=php /app/public/ ./

COPY docker/nginx/nginx.conf       /etc/nginx/nginx.template
COPY docker/nginx/default.conf     /etc/nginx/conf.d/default.template
COPY docker/nginx/default-ssl.conf /etc/nginx/conf.d/default-ssl.template

RUN set -eux; \
    \
    # Remove default config, will be replaced on startup with custom one
    rm /etc/nginx/conf.d/default.conf; \
    \
    # Empty all php files (to reduce container size). Only the file's existence is important
    find . -type f -name "*.php" -exec sh -c 'i="$1"; >"$i"' _ {} \;; \
    \
    # Fix permission
    adduser -u 82 -D -S -G www-data www-data

HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 CMD curl -f http://localhost/ || exit 1

COPY docker/nginx/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
ENTRYPOINT ["docker-entrypoint"]
CMD ["nginx", "-g", "daemon off;"]
