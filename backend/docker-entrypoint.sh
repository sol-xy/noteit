#!/bin/sh
set -eu

data_dir="${DATA_DIR:-/data}"
mkdir -p "$data_dir"

if [ "$(id -u)" = "0" ]; then
    chown -R noteit:noteit "$data_dir"
    exec setpriv --reuid=noteit --regid=noteit --init-groups \
        uvicorn app.main:get_default_app --factory --host 0.0.0.0 --port 8080
fi

exec uvicorn app.main:get_default_app --factory --host 0.0.0.0 --port 8080
