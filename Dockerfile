# syntax=docker/dockerfile:1
#
# Sylius on Railway — nginx + php-fpm in one container, plus the same image
# running as a Messenger worker and as a scheduler (SYLIUS_ROLE selects).
#
# The application itself is the upstream Sylius-Standard skeleton, fetched at
# build time and overlaid with the few files this deployment adds.

ARG PHP_IMAGE=ghcr.io/sylius/sylius-php:8.3-alpine
ARG SYLIUS_STANDARD_REF=2.2
ARG NODE_IMAGE=node:22-alpine

########################################
# 1. Application source + PHP vendors
########################################
FROM ${PHP_IMAGE} AS vendor

ARG SYLIUS_STANDARD_REF
WORKDIR /srv/sylius

RUN set -eux; \
    curl -fsSL "https://github.com/Sylius/Sylius-Standard/archive/refs/heads/${SYLIUS_STANDARD_REF}.tar.gz" -o /tmp/sylius.tar.gz; \
    tar -xzf /tmp/sylius.tar.gz --strip-components=1 -C /srv/sylius; \
    rm -f /tmp/sylius.tar.gz; \
    test -f composer.json

# Files this deployment adds or replaces (config, console command, health route).
COPY app/ /srv/sylius/

# A throwaway URL so the container can be compiled at build time; the real one
# is injected by Railway and resolved at runtime (%env(resolve:DATABASE_URL)%).
ENV APP_ENV=prod \
    APP_DEBUG=0 \
    DATABASE_URL="mysql://sylius:sylius@127.0.0.1:3306/sylius?charset=utf8mb4"

RUN set -eux; \
    composer update --no-dev --no-scripts --no-interaction --prefer-dist --optimize-autoloader; \
    composer clear-cache

########################################
# 2. Front-end assets (Webpack Encore)
########################################
FROM ${NODE_IMAGE} AS assets

WORKDIR /srv/sylius
# Encore resolves several packages out of vendor/, so the PHP install has to
# come first — see package.json's "file:vendor/..." dependencies.
COPY --from=vendor /srv/sylius /srv/sylius

RUN set -eux; \
    yarn install --network-timeout 600000; \
    yarn build:prod; \
    test -d public/build

########################################
# 3. Runtime
########################################
FROM ${PHP_IMAGE}

RUN set -eux; \
    apk add --no-cache nginx supervisor su-exec; \
    apk add --no-cache --virtual .redis-build-deps $PHPIZE_DEPS; \
    pecl install redis; \
    docker-php-ext-enable redis; \
    apk del .redis-build-deps; \
    rm -rf /tmp/pear /var/cache/apk/*; \
    php -m | grep -qx redis; \
    php -m | grep -qx pdo_mysql; \
    php -m | grep -qx intl

COPY docker/php-railway.ini /usr/local/etc/php/conf.d/zz-railway.ini
COPY docker/php-fpm-railway.conf /usr/local/etc/php-fpm.d/zz-railway.conf
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/supervisord.conf /etc/supervisor/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/sylius-entrypoint

WORKDIR /srv/sylius
COPY --from=vendor /srv/sylius /srv/sylius
COPY --from=assets /srv/sylius/public/build /srv/sylius/public/build

ENV APP_ENV=prod \
    APP_DEBUG=0 \
    PHP_DATE_TIMEZONE=UTC \
    JWT_SECRET_KEY=/data/jwt/private.pem \
    JWT_PUBLIC_KEY=/data/jwt/public.pem \
    SYLIUS_PAYMENT_ENCRYPTION_KEY_PATH=/data/encryption/prod.key

RUN set -eux; \
    chmod +x /usr/local/bin/sylius-entrypoint; \
    sh -n /usr/local/bin/sylius-entrypoint; \
    php -l src/Command/RailwayBootstrapCommand.php; \
    php -l src/Controller/RailwayHealthController.php; \
    php bin/console assets:install public --env=prod --no-debug; \
    mkdir -p /srv/sylius/var /srv/sylius/public/media /tmp/nginx; \
    chown -R www-data:www-data /srv/sylius/var /srv/sylius/public; \
    sed 's|__PORT__|8080|g' /etc/nginx/nginx.conf > /tmp/nginx-test.conf; \
    nginx -t -c /tmp/nginx-test.conf; \
    rm -f /tmp/nginx-test.conf; \
    chown -R nginx:nginx /tmp/nginx /var/lib/nginx

EXPOSE 8080
CMD ["/usr/local/bin/sylius-entrypoint"]
