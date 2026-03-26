#!/bin/sh
set -x

rm -rf /app/tmp/pids/server.pid
rm -rf /app/tmp/cache/*

pnpm store prune
pnpm install --force

#install missing gems for local dev as we are using base image compiled for production
bundle install

echo "Ready to run Vite development server."

exec "$@"
