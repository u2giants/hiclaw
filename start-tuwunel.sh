#!/bin/bash
# start-tuwunel.sh - Start Tuwunel Matrix Homeserver
# NOTE: Tuwunel is a conduwuit fork. Environment variables use CONDUWUIT_ prefix.

set -euo pipefail

mkdir -p /data/tuwunel

export CONDUWUIT_SERVER_NAME="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"
export CONDUWUIT_DATABASE_PATH="/data/tuwunel"
export CONDUWUIT_ADDRESS="0.0.0.0"
export CONDUWUIT_PORT=6167
export CONDUWUIT_ALLOW_REGISTRATION=true
export CONDUWUIT_REGISTRATION_TOKEN="${HICLAW_REGISTRATION_TOKEN}"
export CONDUWUIT_ALLOW_LEGACY_MEDIA=true
export CONDUWUIT_ALLOW_UNSTABLE_ROOM_VERSIONS=true
export CONDUWUIT_DB_POOL_WORKERS_LIMIT=32
# Increase default cache capacity to prevent RocksDB thrashing (tuwunel#123)
export CONDUWUIT_CACHE_CAPACITY_MODIFIER="${CONDUWUIT_CACHE_CAPACITY_MODIFIER:-2.0}"

# Agent lifecycle cleanup: collapse rooms once their last local member
# leaves and force a /forget on leave so a recreated same-named
# worker/manager/human starts from a clean room state. See
# hiclaw-controller LeaveAll*Rooms / DeleteRoom flows.
export CONDUWUIT_DELETE_ROOMS_AFTER_LEAVE="${CONDUWUIT_DELETE_ROOMS_AFTER_LEAVE:-true}"
export CONDUWUIT_FORGET_FORCED_UPON_LEAVE="${CONDUWUIT_FORGET_FORCED_UPON_LEAVE:-true}"

# Native Matrix SSO: configure Google directly in Tuwunel so Element can use
# Matrix-side SSO instead of a browser-side password or token workaround.
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-<REPLACE_ME>}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-<REPLACE_ME>}"
GOOGLE_CALLBACK_URL="https://claw.designflow.app/_matrix/client/unstable/login/sso/callback/${GOOGLE_CLIENT_ID}"
GOOGLE_ADMIN_EMAIL="u2giants@gmail.com"
ADMIN_MXID="@${HICLAW_ADMIN_USER:-admin}:${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:18080}"

export TUWUNEL_IDENTITY_PROVIDER__0__BRAND="Google"
export TUWUNEL_IDENTITY_PROVIDER__0__CLIENT_ID="${GOOGLE_CLIENT_ID}"
export TUWUNEL_IDENTITY_PROVIDER__0__CLIENT_SECRET="${GOOGLE_CLIENT_SECRET}"
export TUWUNEL_IDENTITY_PROVIDER__0__CALLBACK_URL="${GOOGLE_CALLBACK_URL}"
export TUWUNEL_IDENTITY_PROVIDER__0__NAME="Google"
export TUWUNEL_IDENTITY_PROVIDER__0__DEFAULT="true"
export TUWUNEL_IDENTITY_PROVIDER__0__REGISTRATION="false"
export TUWUNEL_SINGLE_SSO="true"

# User creation is handled by start-manager-agent.sh via Registration API
# (single-step registration, no UIAA flow needed)
exec tuwunel \
  --execute "query oauth associate ${GOOGLE_CLIENT_ID} ${ADMIN_MXID} --claim email=${GOOGLE_ADMIN_EMAIL}"
