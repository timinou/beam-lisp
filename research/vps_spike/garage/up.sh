#!/usr/bin/env bash
# up.sh — bring up a local Garage S3 (the off-box durable tier), rootless.
# Emits creds to $GD/creds.env for the checkpoint spike to source.
# Usage: research/vps_spike/garage/up.sh   → prints ENDPOINT/KEY/SECRET/BUCKET
set -e
GD="${GARAGE_DIR:-/tmp/vps-garage}"
BIN="${GARAGE_BIN:-garage}"
mkdir -p "$GD/meta" "$GD/data"

if [ ! -f "$GD/garage.toml" ]; then
  RPC=$(openssl rand -hex 32); ADM=$(openssl rand -hex 16)
  cat > "$GD/garage.toml" <<EOF
metadata_dir = "$GD/meta"
data_dir = "$GD/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "$RPC"
[s3_api]
s3_region = "garage"
api_bind_addr = "127.0.0.1:3900"
root_domain = ".s3.garage.localhost"
[admin]
api_bind_addr = "127.0.0.1:3903"
admin_token = "$ADM"
EOF
fi

G="$BIN -c $GD/garage.toml"
# already serving?
if ! $G status >/dev/null 2>&1; then
  # close inherited fds 3-9 (this host's daemon-spawn rule) so shell entry never hangs
  setsid $BIN -c "$GD/garage.toml" server >"$GD/garage.log" 2>&1 </dev/null \
    3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
  for i in $(seq 1 20); do $G status >/dev/null 2>&1 && break; sleep 0.5; done
fi

# assign a role to this single node if it has none
if $G status 2>/dev/null | grep -q "NO ROLE ASSIGNED"; then
  NODE=$($G node id -q 2>/dev/null | cut -d@ -f1)
  V=$($G layout show 2>/dev/null | grep -oE 'version [0-9]+' | grep -oE '[0-9]+' | head -1 || echo 0)
  $G layout assign -z dc1 -c 1G "$NODE" >/dev/null 2>&1 || true
  $G layout apply --version $((V + 1)) >/dev/null 2>&1 || true
  sleep 1
fi

# idempotent bucket + key
$G bucket create bl-blobs >/dev/null 2>&1 || true
if ! $G key info bl-key >/dev/null 2>&1; then
  $G key create bl-key >/dev/null 2>&1 || true
fi
$G bucket allow --read --write --owner bl-blobs --key bl-key >/dev/null 2>&1 || true

KID=$($G key info --show-secret bl-key 2>/dev/null | awk -F': *' '/Key ID/{print $2}')
SEC=$($G key info --show-secret bl-key 2>/dev/null | awk -F': *' '/Secret key/{print $2}')
cat > "$GD/creds.env" <<EOF
S3_ENDPOINT=http://127.0.0.1:3900
S3_BUCKET=bl-blobs
S3_ACCESS_KEY=$KID
S3_SECRET_KEY=$SEC
EOF
echo "garage up: endpoint=http://127.0.0.1:3900 bucket=bl-blobs key=$KID"
