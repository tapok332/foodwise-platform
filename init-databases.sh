#!/usr/bin/env bash
# First-boot bootstrap for the single PostgreSQL/PostGIS instance:
# creates one database and one restricted login role per service.
#
# Executed by the postgres image from /docker-entrypoint-initdb.d — i.e. only
# when the data volume is empty. Passwords are NOT hardcoded here: they come
# from the *_DB_PASSWORD environment variables that docker-compose forwards
# from your .env (see .env.example). The script fails fast when one is missing,
# so a half-configured environment never produces a half-initialized cluster.
set -euo pipefail

# <service>:<database>:<password env var>:<postgis flag>
SERVICES="
auth:foodwise_auth:AUTH_DB_PASSWORD:
profile:foodwise_profile:PROFILE_DB_PASSWORD:
store:foodwise_stores:STORE_DB_PASSWORD:postgis
surprisebox:foodwise_surprisebox:SURPRISEBOX_DB_PASSWORD:postgis
cart:foodwise_cart:CART_DB_PASSWORD:
order:foodwise_orders:ORDER_DB_PASSWORD:
payment:foodwise_payment:PAYMENT_DB_PASSWORD:
favorites:foodwise_favorites:FAVORITES_DB_PASSWORD:
"

for entry in $SERVICES; do
    IFS=: read -r name db pwd_env postgis <<<"$entry"
    pwd="${!pwd_env:-}"
    if [ -z "$pwd" ]; then
        echo "ERROR: $pwd_env is not set — add it to .env (see .env.example)." >&2
        exit 1
    fi
    user="${name}_user"
    echo "Initializing $db (role: $user)"

    # psql variables (:'pwd' / :"user") give proper literal/identifier quoting.
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
         -v db="$db" -v user="$user" -v pwd="$pwd" <<'EOSQL'
CREATE DATABASE :"db";
CREATE ROLE :"user" LOGIN PASSWORD :'pwd';
GRANT CONNECT ON DATABASE :"db" TO :"user";
EOSQL

    extensions='CREATE EXTENSION IF NOT EXISTS "uuid-ossp";'
    if [ "$postgis" = "postgis" ]; then
        extensions="$extensions
CREATE EXTENSION IF NOT EXISTS postgis CASCADE;
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS earthdistance CASCADE;"
    fi

    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" -v user="$user" <<EOSQL
$extensions
GRANT ALL PRIVILEGES ON SCHEMA public TO :"user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO :"user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO :"user";
EOSQL
done

echo "All FoodWise databases initialized."
