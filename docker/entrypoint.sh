#!/bin/sh
# Sylius on Railway. One image, three roles:
#   SYLIUS_ROLE=web        nginx + php-fpm; owns migrations and first-boot setup
#   SYLIUS_ROLE=worker     Symfony Messenger consumer
#   SYLIUS_ROLE=scheduler  the recurring maintenance commands Sylius documents
set -eu

ROLE="${SYLIUS_ROLE:-web}"
PORT="${PORT:-8080}"
DATA_DIR="${RAILWAY_VOLUME_MOUNT_PATH:-/data}"
APP_DIR=/srv/sylius

log() { echo "[railway] $*"; }

export APP_ENV="${APP_ENV:-prod}"
export APP_DEBUG="${APP_DEBUG:-0}"

# ---------------------------------------------------------------- database ---
# Railway's MYSQL_URL carries no query string; Doctrine wants the charset.
if [ -z "${DATABASE_URL:-}" ]; then
    log "FATAL: DATABASE_URL is empty - reference \${{MySQL.MYSQL_URL}} on this service."
    exit 1
fi
case "$DATABASE_URL" in
    *\?*) : ;;
    *) DATABASE_URL="${DATABASE_URL}?charset=utf8mb4" ;;
esac
export DATABASE_URL

# ------------------------------------------------------------------- redis ---
# The Symfony cache pool and the session handler both live in Redis, so a
# redeploy does not sign every shopper out. Separate databases keep a cache
# clear from touching sessions.
if [ -n "${REDIS_URL:-}" ]; then
    export SESSION_HANDLER_DSN="${SESSION_HANDLER_DSN:-${REDIS_URL}/1}"
else
    log "WARNING: REDIS_URL is empty - sessions fall back to files on the volume."
    export SESSION_HANDLER_DSN="${SESSION_HANDLER_DSN:-file://${DATA_DIR}/sessions}"
fi

# -------------------------------------------------------------------- mail ---
# ${{mailpit.RAILWAY_PRIVATE_DOMAIN}} renders empty until that service owns a
# deployment, which is exactly what a template's first deploy looks like, so
# repair the DSN on its shape rather than trusting the reference.
case "${MAILER_DSN:-}" in
    ""|"smtp://:"*|"smtp://:1025") MAILER_DSN="smtp://mailpit.railway.internal:1025" ;;
esac
export MAILER_DSN

# ------------------------------------------------------------------- paths ---
mkdir -p \
    "$DATA_DIR/media" \
    "$DATA_DIR/jwt" \
    "$DATA_DIR/encryption" \
    "$DATA_DIR/sessions" \
    "$APP_DIR/var/cache" \
    "$APP_DIR/var/log"

# public/media is a symlink onto the volume; Liip Imagine writes its thumbnail
# cache under the same tree, so both survive a redeploy.
if [ ! -L "$APP_DIR/public/media" ]; then
    rm -rf "$APP_DIR/public/media"
    ln -sfn "$DATA_DIR/media" "$APP_DIR/public/media"
fi

export JWT_SECRET_KEY="${JWT_SECRET_KEY:-$DATA_DIR/jwt/private.pem}"
export JWT_PUBLIC_KEY="${JWT_PUBLIC_KEY:-$DATA_DIR/jwt/public.pem}"
export SYLIUS_PAYMENT_ENCRYPTION_KEY_PATH="${SYLIUS_PAYMENT_ENCRYPTION_KEY_PATH:-$DATA_DIR/encryption/prod.key}"

chown -R www-data:www-data "$DATA_DIR" "$APP_DIR/var" 2>/dev/null || true

# --------------------------------------------------------------- php + tz ----
if [ -n "${PHP_DATE_TIMEZONE:-}" ]; then
    sed -i "s|^date.timezone = .*|date.timezone = ${PHP_DATE_TIMEZONE}|" \
        /usr/local/etc/php/conf.d/zz-railway.ini
fi

# Every console call runs as the same user php-fpm does, so nothing it writes
# under var/ or the volume is left root-owned.
console() {
    ( cd "$APP_DIR" && su-exec www-data php bin/console "$@" )
}

wait_for_schema() {
    i=0
    until console doctrine:migrations:up-to-date --no-interaction >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge 90 ]; then
            log "the schema never became current"
            return 1
        fi
        [ $((i % 6)) -eq 1 ] && log "waiting for the web service to migrate ($i)..."
        sleep 10
    done
    return 0
}

write_payment_key() {
    if [ -n "${SYLIUS_PAYMENT_ENCRYPTION_KEY:-}" ]; then
        mkdir -p "$(dirname "$SYLIUS_PAYMENT_ENCRYPTION_KEY_PATH")"
        printf '%s' "$SYLIUS_PAYMENT_ENCRYPTION_KEY" > "$SYLIUS_PAYMENT_ENCRYPTION_KEY_PATH"
        chown www-data:www-data "$SYLIUS_PAYMENT_ENCRYPTION_KEY_PATH"
    elif [ ! -f "$SYLIUS_PAYMENT_ENCRYPTION_KEY_PATH" ]; then
        log "generating the payment encryption key"
        console sylius:payment:generate-key --overwrite --no-interaction || true
    fi
}

# ------------------------------------------------------------------- roles ---
case "$ROLE" in
web)
    log "role=web port=$PORT"

    log "running database migrations"
    i=0
    until console doctrine:migrations:migrate --no-interaction --allow-no-migration; do
        i=$((i + 1))
        if [ "$i" -ge 30 ]; then
            log "migrations failed after 30 attempts"
            exit 1
        fi
        log "database not ready yet, retrying ($i)..."
        sleep 10
    done

    # A per-database marker: pointing the app at a different database has to
    # re-run the bootstrap, and a volume-scoped flag would suppress it.
    DB_ID=$(printf '%s' "$DATABASE_URL" | sha256sum | cut -c1-16)
    MARKER="$DATA_DIR/.bootstrapped-$DB_ID"

    if [ ! -f "$MARKER" ]; then
        if [ "${SYLIUS_SAMPLE_DATA:-true}" = "true" ]; then
            log "loading the sample catalogue (SYLIUS_SAMPLE_DATA=false starts empty)"
            console sylius:fixtures:load default --no-interaction \
                || log "sample data failed; continuing with an empty catalogue"
        fi
        log "first-boot setup"
        console railway:bootstrap --purge-other-admins --no-interaction
        touch "$MARKER"
    else
        console railway:bootstrap --no-interaction
    fi

    # JWT keypair for the Sylius API, kept on the volume so tokens issued
    # before a redeploy stay valid.
    if [ ! -f "$JWT_SECRET_KEY" ]; then
        log "generating the API JWT keypair"
        console lexik:jwt:generate-keypair --overwrite --no-interaction
    fi

    write_payment_key

    # Some Symfony cache warmers open a database connection, so the cache is
    # built here rather than in the image, where no database exists.
    log "warming the application cache"
    console cache:warmup --no-interaction

    chown -R www-data:www-data "$DATA_DIR" "$APP_DIR/var" 2>/dev/null || true

    sed -i "s|__PORT__|${PORT}|g" /etc/nginx/nginx.conf
    mkdir -p /tmp/nginx
    chown -R nginx:nginx /tmp/nginx

    log "starting php-fpm and nginx"
    exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
    ;;

worker)
    log "role=worker"
    wait_for_schema || exit 1
    write_payment_key
    TRANSPORTS="${SYLIUS_MESSENGER_TRANSPORTS:-main catalog_promotion_removal}"
    log "consuming transports: $TRANSPORTS"
    cd "$APP_DIR"
    exec su-exec www-data php bin/console messenger:consume $TRANSPORTS \
        --no-interaction \
        --time-limit="${SYLIUS_WORKER_TIME_LIMIT:-3600}" \
        --memory-limit="${SYLIUS_WORKER_MEMORY_LIMIT:-256M}" -v
    ;;

scheduler)
    log "role=scheduler"
    wait_for_schema || exit 1
    # Railway templates drop deploy.cronSchedule, so recurring work is a
    # long-lived loop rather than a cron service.
    INTERVAL="${SYLIUS_SCHEDULER_INTERVAL:-3600}"
    while true; do
        log "cancelling unpaid orders"
        console sylius:cancel-unpaid-orders --no-interaction || true
        log "removing expired carts"
        console sylius:remove-expired-carts --no-interaction || true
        log "next run in ${INTERVAL}s"
        sleep "$INTERVAL"
    done
    ;;

*)
    log "unknown SYLIUS_ROLE '$ROLE'"
    exit 1
    ;;
esac
