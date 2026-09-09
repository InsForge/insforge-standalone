#!/bin/bash
# Exercises insforge-imds-guard with iptables, systemctl, install, sudo, id and
# the container CLIs stubbed onto PATH, so it runs unprivileged on a laptop
# (bash 3.2 included) and never touches the host firewall.
#
# The first case is the one that matters most: the pinned MAC is a literal in
# three files that cannot share a variable, and a drift between them leaves a
# rule that matches nothing while `status` still reports ACTIVE.
#
# Usage: insforge-imds-guard.test.sh   (from the insforge-standalone checkout)
set -uo pipefail

cd "$(dirname "$0")"
GUARD=$PWD/insforge-imds-guard
STUBS=$(mktemp -d)
export IPT_STATE=$STUBS/iptables.state IPT_LOG=$STUBS/iptables.log CALL_LOG=$STUBS/calls.log
export DOCKER_MAC="" DOCKER_EXEC_RC=124
trap 'rm -rf "$STUBS"' EXIT
: > "$IPT_STATE"

pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
reset() { : > "$IPT_STATE"; : > "$IPT_LOG"; : > "$CALL_LOG"; }

# --- stubs -------------------------------------------------------------------
# iptables keeps the rule set in a file. The op flag is stripped so -C/-I/-D
# compare the same key, which is exactly what the real chain would do.
cat > "$STUBS/iptables" <<'STUB'
#!/bin/bash
args="$*"
case " $args " in
  *" -C "*) op=C ;; *" -I "*) op=I ;; *" -D "*) op=D ;; *) op=other ;;
esac
key=$(printf '%s' "$args" | sed -E 's/^-w 5 -t raw -[CID] //')
echo "$op $key" >> "$IPT_LOG"
case $op in
  C) grep -qxF -- "$key" "$IPT_STATE" ;;
  I) echo "$key" >> "$IPT_STATE" ;;
  D) grep -vxF -- "$key" "$IPT_STATE" > "$IPT_STATE.tmp"; mv "$IPT_STATE.tmp" "$IPT_STATE" ;;
esac
STUB
cat > "$STUBS/id" <<'STUB'
#!/bin/bash
echo 0
STUB
cat > "$STUBS/sudo" <<'STUB'
#!/bin/bash
while [ "${1#-}" != "$1" ]; do shift; done
exec "$@"
STUB
for tool in systemctl install; do
  cat > "$STUBS/$tool" <<STUB
#!/bin/bash
echo "$tool \$*" >> "\$CALL_LOG"
STUB
done
cat > "$STUBS/podman" <<'STUB'
#!/bin/bash
exit 1
STUB
cat > "$STUBS/docker" <<'STUB'
#!/bin/bash
case "$1" in
  inspect) [ -n "$DOCKER_MAC" ] || exit 1            # no MAC = no container
           if [ "$2" = -f ]; then printf '%s\n' "$DOCKER_MAC"; fi
           exit 0 ;;
  exec)    exit "$DOCKER_EXEC_RC" ;;
esac
STUB
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

# --- 1. the three MAC literals agree ---------------------------------------
mac_script=$(sed -nE 's/^PG_MAC=([0-9a-f:]+)$/\1/p' insforge-imds-guard)
mac_compose=$(sed -nE 's/^[[:space:]]*mac_address:[[:space:]]*"?([0-9a-f:]+)"?.*/\1/p' docker-compose.yml)
mac_quadlet=$(sed -nE 's/.*--mac-address=([0-9a-f:]+).*/\1/p' systemd/insforge-postgres.container)
if [ -n "$mac_script" ] && [ "$mac_script" = "$mac_compose" ] && [ "$mac_script" = "$mac_quadlet" ]; then
  ok "MAC literal agrees across script, docker-compose.yml and quadlet ($mac_script)"
else
  bad "MAC drift: script='$mac_script' compose='$mac_compose' quadlet='$mac_quadlet'"
fi
grep -q "^ExecStart=/usr/local/bin/insforge-imds-guard apply$" insforge-imds-guard.service \
  && ok "unit ExecStart points at the installed guard" || bad "unit ExecStart mismatch"

# --- 2. apply is idempotent; remove clears; status reports -----------------
reset
"$GUARD" status >/dev/null 2>&1 && bad "status exits 0 with no rule" || ok "status exits 1 with no rule"
"$GUARD" apply >/dev/null && "$GUARD" apply >/dev/null
inserts=$(grep -c '^I ' "$IPT_LOG")
[ "$inserts" = 1 ] && ok "two applies insert once" || bad "two applies inserted $inserts times"
rule=$(cat "$IPT_STATE")
case "$rule" in
  "PREROUTING -m mac --mac-source $mac_script -d 169.254.169.254/32 -m comment --comment insforge-imds-guard -j DROP")
    ok "rule shape: raw/PREROUTING, mac-source, IMDS /32, DROP" ;;
  *) bad "unexpected rule: $rule" ;;
esac
"$GUARD" status >/dev/null && ok "status exits 0 with the rule" || bad "status exits 1 with the rule"
"$GUARD" remove >/dev/null
[ ! -s "$IPT_STATE" ] && ok "remove clears the rule" || bad "remove left: $(cat "$IPT_STATE")"

# --- 3. install: copies, enables, applies ------------------------------------
reset
"$GUARD" install >/dev/null || bad "install exited non-zero"
grep -q "^install -m 0755 $GUARD /usr/local/bin/insforge-imds-guard$" "$CALL_LOG" \
  && ok "install copies the script to /usr/local/bin" || bad "script not installed: $(cat "$CALL_LOG")"
grep -q "^install -m 0644 $PWD/insforge-imds-guard.service /etc/systemd/system/insforge-imds-guard.service$" "$CALL_LOG" \
  && ok "install copies the unit" || bad "unit not installed"
grep -q "^systemctl enable --now insforge-imds-guard.service$" "$CALL_LOG" \
  && ok "install enables the unit" || bad "unit not enabled"
[ -s "$IPT_STATE" ] && ok "install applies the rule immediately" || bad "install did not apply"

# --- 4. verify: MAC pin and connect probe ----------------------------------
reset; "$GUARD" apply >/dev/null
out=$(DOCKER_MAC=$mac_script DOCKER_EXEC_RC=124 "$GUARD" verify 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "carries the pinned MAC" && printf '%s' "$out" | grep -q "cannot connect to IMDS"; then
  ok "verify passes: rule + pinned MAC checked + connect times out"
else
  bad "verify good case: rc=$rc, output: $out"
fi
DOCKER_MAC=02:42:ac:11:00:02 DOCKER_EXEC_RC=124 "$GUARD" verify >/dev/null 2>&1 \
  && bad "verify passed with the wrong MAC" || ok "verify fails when the container is not pinned"
DOCKER_MAC=$mac_script DOCKER_EXEC_RC=0 "$GUARD" verify >/dev/null 2>&1 \
  && bad "verify passed although the container reached IMDS" || ok "verify fails when the connect succeeds"
DOCKER_MAC="" "$GUARD" verify >/dev/null 2>&1 \
  && ok "verify passes on rule alone when no container is running" || bad "verify failed with no container"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
