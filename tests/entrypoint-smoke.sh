#!/bin/bash
set -Eeuo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/data"

cat > "$TEST_ROOT/bin/mtg-go" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$TEST_ARGS_FILE"
sleep 30
EOF
chmod +x "$TEST_ROOT/bin/mtg-go"

cat > "$TEST_ROOT/bin/telemt" <<'EOF'
#!/bin/sh
sleep 30
EOF
chmod +x "$TEST_ROOT/bin/telemt"

run_entrypoint() {
    local mode="$1"
    PATH="$TEST_ROOT/bin:$PATH" \
    DATA_DIR="$TEST_ROOT/data" \
    TEST_ARGS_FILE="$TEST_ROOT/args" \
    ENGINE=mtg PORT=18443 FAKEDOMAIN=www.apple.com IP_MODE="$mode" HOST_IP=203.0.113.10 \
        timeout 4 bash "$REPO_DIR/entrypoint.sh" >/dev/null 2>&1 || [ "$?" -eq 124 ]
}

run_entrypoint v4
FIRST_SECRET=$(sed -n 's/^SECRET=//p' "$TEST_ROOT/data/mtg.conf")
FIRST_MTIME=$(stat -c %Y "$TEST_ROOT/data/mtg.conf")
grep -Fq 'only-ipv4 0.0.0.0:18443' "$TEST_ROOT/args"

sleep 1
run_entrypoint v4
SECOND_SECRET=$(sed -n 's/^SECRET=//p' "$TEST_ROOT/data/mtg.conf")
SECOND_MTIME=$(stat -c %Y "$TEST_ROOT/data/mtg.conf")
[ "$FIRST_SECRET" = "$SECOND_SECRET" ]
[ "$FIRST_MTIME" = "$SECOND_MTIME" ]

touch "$TEST_ROOT/data/.regenerate-config"
run_entrypoint v6
THIRD_SECRET=$(sed -n 's/^SECRET=//p' "$TEST_ROOT/data/mtg.conf")
[ "$SECOND_SECRET" != "$THIRD_SECRET" ]
[ ! -e "$TEST_ROOT/data/.regenerate-config" ]
grep -Fq 'prefer-ipv6 [::]:18443' "$TEST_ROOT/args"

if command -v jq >/dev/null 2>&1; then
    rm -rf "$TEST_ROOT/data"
    mkdir -p "$TEST_ROOT/data"
    PATH="$TEST_ROOT/bin:$PATH" DATA_DIR="$TEST_ROOT/data" ENGINE=telemt PORT=18443 \
        FAKEDOMAIN=www.apple.com IP_MODE=v6 HOST_IP=203.0.113.10 \
        timeout 3 bash "$REPO_DIR/entrypoint.sh" >/dev/null 2>&1 || [ "$?" -eq 124 ]
    [ "$(grep -c '^\[\[server.listeners\]\]$' "$TEST_ROOT/data/telemt.toml")" -eq 1 ]
    grep -Fq 'ip = "::"' "$TEST_ROOT/data/telemt.toml"
    ! grep -Fq 'ip = "0.0.0.0"' "$TEST_ROOT/data/telemt.toml"

    cat > "$TEST_ROOT/bin/telemt" <<'EOF'
#!/bin/sh
exit 126
EOF
    chmod +x "$TEST_ROOT/bin/telemt"
    if PATH="$TEST_ROOT/bin:$PATH" DATA_DIR="$TEST_ROOT/data" ENGINE=telemt PORT=18443 \
        FAKEDOMAIN=www.apple.com IP_MODE=v4 HOST_IP=203.0.113.10 \
        bash "$REPO_DIR/entrypoint.sh" >"$TEST_ROOT/failed-start.log" 2>&1; then
        echo "expected telemt startup to fail" >&2
        exit 1
    fi
    ! grep -Fq 'tg://proxy' "$TEST_ROOT/failed-start.log"
fi

echo "entrypoint smoke tests passed"
