# Sylius on Railway

Deployment image for [Sylius](https://github.com/Sylius/Sylius), the headless
eCommerce platform built on Symfony and API Platform.

The application itself is upstream's `Sylius-Standard` skeleton, fetched at
build time from the maintained `2.2` branch and overlaid with the handful of
files in `app/`. Nothing in this repository forks Sylius.

## What the image contains

| Piece | Why |
|---|---|
| `ghcr.io/sylius/sylius-php:8.3-alpine` | upstream's own PHP-FPM base image |
| nginx + supervisor | Railway gives one port per service, so the web tier serves PHP-FPM and the static `public/` tree from a single container |
| `pecl redis` | Symfony's cache pool and session handler both run on Redis |
| Webpack Encore build | `yarn build:prod` runs at image build; Railway has no place to run it later |

## Roles

One image, selected with `SYLIUS_ROLE`:

- `web` — nginx + php-fpm. Runs migrations, first-boot setup, and generates the
  JWT keypair and payment encryption key onto the volume.
- `worker` — `messenger:consume main catalog_promotion_removal`.
- `scheduler` — loops `sylius:cancel-unpaid-orders` and
  `sylius:remove-expired-carts`; Railway templates drop `cronSchedule`, so
  recurring work has to be a long-lived process.

## First boot

`railway:bootstrap` (added in `app/src/Command`) runs `sylius:install:setup`
only while no channel exists, then converts the installer's
`sylius@example.com` account into the operator's own using
`SYLIUS_ADMIN_EMAIL` / `SYLIUS_ADMIN_PASSWORD`, and disables any other
administrator the sample-data fixtures created. All of it happens before nginx
starts, so the shipped credentials are never reachable. An administrator that
already exists is never modified, so a password changed in the admin panel
survives redeploys.

## Environment

| Variable | Default | Notes |
|---|---|---|
| `DATABASE_URL` | — | `${{MySQL.MYSQL_URL}}`; the entrypoint appends `?charset=utf8mb4` |
| `REDIS_URL` | — | `${{Redis.REDIS_URL}}`; cache on db 0, sessions on db 1 |
| `APP_SECRET` | — | Symfony signing secret; must stay stable |
| `SYLIUS_ADMIN_EMAIL` | `admin@example.com` | first administrator |
| `SYLIUS_ADMIN_PASSWORD` | — | required; no default is ever assumed |
| `SYLIUS_SAMPLE_DATA` | `true` | loads Sylius' demo catalogue on the first boot only |
| `TRUSTED_PROXIES` | `100.64.0.0/10,fd00::/8,152.233.0.0/17` | Railway's edge ranges |
| `MAILER_DSN` | `null://null` | point at Mailpit or a real relay |
| `JWT_PASSPHRASE` | — | protects the generated API keypair |
| `SYLIUS_PAYMENT_ENCRYPTION_KEY` | unset | set to share one key across roles; otherwise the web role generates and keeps it on the volume |
| `SYLIUS_SCHEDULER_INTERVAL` | `3600` | seconds between scheduler passes |

## Volume

Mount one volume on the `web` service; the entrypoint reads
`RAILWAY_VOLUME_MOUNT_PATH` (`/data`) and keeps `media/` (symlinked from
`public/media`), `jwt/`, `encryption/` and the first-boot marker there.

MIT, like Sylius itself.
