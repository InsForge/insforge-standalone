#!/bin/bash
# Exercises insforge-aws-creds against a fake IMDS on localhost, with `id` and
# `sudo` stubbed onto PATH, so it runs unprivileged on a laptop and never
# touches a real metadata service. The fake rejects any metadata read without
# an IMDSv2 token, which is the only mode the fleet allows.
#
# Usage: insforge-aws-creds.test.sh   (from the insforge-standalone checkout)
set -uo pipefail

cd "$(dirname "$0")" || exit 1
CREDS=$PWD/insforge-aws-creds
WORK=$(mktemp -d)
STUBS=$WORK/stubs; OUT=$WORK/out; mkdir -p "$STUBS"
export INSFORGE_AWS_CREDS_DIR=$OUT FAKE_STATE=$WORK/imds.json CHOWN_LOG=$WORK/chown.log
pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

cat > "$STUBS/id" <<'STUB'
#!/bin/bash
echo 0
STUB
# chown would need root; record what was asked instead.
cat > "$STUBS/chown" <<'STUB'
#!/bin/bash
echo "chown $*" >> "$CHOWN_LOG"
STUB
cat > "$STUBS/sudo" <<'STUB'
#!/bin/bash
while [ "${1#-}" != "$1" ]; do shift; done
exec "$@"
STUB
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

# Fake IMDS. Serves whatever $FAKE_STATE holds as the role credentials, so a
# case can change them between refreshes.
cat > "$WORK/imds.py" <<'PY'
import http.server, json, os, sys
TOKEN = "tok-123"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body=""):
        self.send_response(code); self.end_headers(); self.wfile.write(body.encode())
    def do_PUT(self):
        if self.path == "/latest/api/token" and self.headers.get("X-aws-ec2-metadata-token-ttl-seconds"):
            return self._send(200, TOKEN)
        self._send(400)
    def do_GET(self):
        if self.headers.get("X-aws-ec2-metadata-token") != TOKEN:
            return self._send(401)
        base = "/latest/meta-data/iam/security-credentials/"
        if self.path == base:
            return self._send(200, "EC2-role\n")
        if self.path == base + "EC2-role":
            return self._send(200, open(os.environ["FAKE_STATE"]).read())
        self._send(404)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
creds_json() { # key code expiration
  printf '{"Code":"%s","Type":"AWS-HMAC","AccessKeyId":"%s","SecretAccessKey":"secret-%s","Token":"token-%s","Expiration":"%s"}' \
    "$2" "$1" "$1" "$1" "$3"
}
future=$(python3 -I -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=6)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
creds_json ASIAFIRST Success "$future" > "$FAKE_STATE"
python3 -I "$WORK/imds.py" > "$WORK/port" &
IMDS_PID=$!
trap 'kill $IMDS_PID 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
INSFORGE_IMDS_ENDPOINT="http://127.0.0.1:$(cat "$WORK/port")"
export INSFORGE_IMDS_ENDPOINT

# 1. refresh writes credential_process output the SDK accepts.
if "$CREDS" refresh >/dev/null 2>&1 && python3 -I - "$OUT/credentials.json" "$future" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d == {"Version": 1, "AccessKeyId": "ASIAFIRST", "SecretAccessKey": "secret-ASIAFIRST",
             "SessionToken": "token-ASIAFIRST", "Expiration": sys.argv[2]}, d
PY
then ok "refresh writes Version/keys/SessionToken/Expiration"; else bad "refresh output"; fi

# 2. config points credential_process at that file.
if [ "$(cat "$OUT/config" 2>/dev/null)" = "$(printf '[default]\ncredential_process = cat %s/credentials.json' "$OUT")" ]; then
  ok "config names credential_process = cat <file>"
else bad "config content: $(cat "$OUT/config" 2>/dev/null)"; fi

# 3. the role's secret is root:1000 0640 — readable by the app's `node` user
#    (gid 1000) and root, by no other host user — and nothing is left behind.
if [ "$(stat -c %a "$OUT/credentials.json" 2>/dev/null || stat -f %Lp "$OUT/credentials.json")" = 640 ] \
   && grep -qE '^chown 0:1000 .*/\.credentials\.' "$CHOWN_LOG" \
   && ! compgen -G "$OUT/.*.??????" >/dev/null; then
  ok "credentials.json is root:1000 0640 and no temp files remain"
else bad "permissions/owner/temp files: $(ls -la "$OUT"; cat "$CHOWN_LOG" 2>/dev/null)"; fi

# 4. a rotated role is picked up on the next refresh.
creds_json ASIASECOND Success "$future" > "$FAKE_STATE"
"$CREDS" refresh >/dev/null 2>&1
if grep -q ASIASECOND "$OUT/credentials.json"; then ok "refresh picks up rotated credentials"; else bad "rotation not picked up"; fi

# 5. an IMDS error leaves the last good file in place and fails loudly.
creds_json ASIABROKEN Failure "$future" > "$FAKE_STATE"
if ! "$CREDS" refresh >/dev/null 2>&1 && grep -q ASIASECOND "$OUT/credentials.json"; then
  ok "IMDS failure exits non-zero and keeps the last good credentials"
else bad "IMDS failure handling"; fi

# 5b. an already-expired or unparseable Expiration is rejected the same way.
creds_json ASIASTALE Success "2020-01-01T00:00:00Z" > "$FAKE_STATE"
if ! "$CREDS" refresh >/dev/null 2>&1 && grep -q ASIASECOND "$OUT/credentials.json"; then
  ok "expired Expiration from IMDS is rejected; last good credentials kept"
else bad "expired Expiration accepted"; fi
creds_json ASIAGARBLE Success "tomorrow-ish" > "$FAKE_STATE"
if ! "$CREDS" refresh >/dev/null 2>&1 && grep -q ASIASECOND "$OUT/credentials.json"; then
  ok "malformed Expiration from IMDS is rejected; last good credentials kept"
else bad "malformed Expiration accepted"; fi
creds_json ASIASECOND Success "$future" > "$FAKE_STATE"

# 6. status: OK while valid, failing on a wrong config, once expired, or missing.
if "$CREDS" status >/dev/null 2>&1; then ok "status OK on valid credentials"; else bad "status on valid credentials"; fi
cp "$OUT/config" "$WORK/config.good"
printf '[default]\ncredential_process = cat /elsewhere/credentials.json\n' > "$OUT/config"
if ! "$CREDS" status >/dev/null 2>&1; then ok "status fails when config points elsewhere"; else bad "status ignored a wrong config"; fi
rm -f "$OUT/config"
if ! "$CREDS" status >/dev/null 2>&1; then ok "status fails when config is missing"; else bad "status ignored a missing config"; fi
"$CREDS" refresh >/dev/null 2>&1
if cmp -s "$OUT/config" "$WORK/config.good"; then ok "refresh rewrites a missing config"; else bad "refresh did not restore config"; fi
python3 -I - "$OUT/credentials.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["Expiration"] = "2020-01-01T00:00:00Z"; json.dump(d, open(p, "w"))
PY
if ! "$CREDS" status >/dev/null 2>&1; then ok "status fails on expired credentials"; else bad "status on expired credentials"; fi
rm -f "$OUT/credentials.json"
if ! "$CREDS" status >/dev/null 2>&1; then ok "status fails when the file is missing"; else bad "status on missing file"; fi

# 7. the units the app depends on exist and agree with the paths used here.
if grep -q '^Volume=/run/insforge-aws:/run/insforge-aws:ro$' systemd/insforge.container \
   && grep -q '^Environment=AWS_CONFIG_FILE=/run/insforge-aws/config$' systemd/insforge.container \
   && grep -q -- '- /run/insforge-aws:/run/insforge-aws:ro' docker-compose.yml \
   && grep -q -- '- AWS_CONFIG_FILE=/run/insforge-aws/config' docker-compose.yml \
   && grep -q '^OUT_DIR=${INSFORGE_AWS_CREDS_DIR:-/run/insforge-aws}$' "$CREDS"; then
  ok "quadlet, compose and script agree on /run/insforge-aws"
else bad "mount/env path drift between quadlet, compose and script"; fi

# 8. install: copies the script and both units, reloads systemd, enables the
#    timer, and writes the credentials immediately (the app may start next).
export CALL_LOG=$WORK/calls.log
: > "$CALL_LOG"
for tool in systemctl install; do
  cat > "$STUBS/$tool" <<STUB
#!/bin/bash
echo "$tool \$*" >> "\$CALL_LOG"
STUB
  chmod +x "$STUBS/$tool"
done
rm -f "$OUT/credentials.json"
if "$CREDS" install >/dev/null 2>&1 \
   && grep -qx "install -m 0755 $CREDS /usr/local/bin/insforge-aws-creds" "$CALL_LOG" \
   && grep -qx "install -m 0644 $PWD/insforge-aws-creds.service /etc/systemd/system/insforge-aws-creds.service" "$CALL_LOG" \
   && grep -qx "install -m 0644 $PWD/insforge-aws-creds.timer /etc/systemd/system/insforge-aws-creds.timer" "$CALL_LOG" \
   && [ "$(grep -n 'systemctl daemon-reload' "$CALL_LOG" | cut -d: -f1)" -lt "$(grep -n 'systemctl enable --now insforge-aws-creds.timer' "$CALL_LOG" | cut -d: -f1)" ] \
   && grep -q ASIASECOND "$OUT/credentials.json"; then
  ok "install copies script + both units, daemon-reloads, enables the timer, refreshes now"
else bad "install lifecycle: $(cat "$CALL_LOG")"; fi

# 9. install refuses to run outside the checkout (units not next to it).
mkdir -p "$WORK/elsewhere" && cp "$CREDS" "$WORK/elsewhere/insforge-aws-creds"
if ! "$WORK/elsewhere/insforge-aws-creds" install >/dev/null 2>&1; then
  ok "install outside the checkout fails instead of installing without units"
else bad "install ran without its units"; fi

# 10. insforge-ctl installs it on up and restart, after the guard, before the
#     stack starts, and never lets a failure abort the verb.
ctl_has() { awk -v verb="$1" '
  $0 ~ "^  " verb "\\)$" {in_v=1; next}
  in_v && /^    ;;$/ {exit}
  in_v {print}' insforge-ctl; }
up_ok=1
for verb in up restart; do
  body=$(ctl_has "$verb")
  g=$(printf '%s\n' "$body" | grep -n 'ensure_imds_guard' | cut -d: -f1)
  c=$(printf '%s\n' "$body" | grep -n 'ensure_aws_creds' | cut -d: -f1)
  s=$(printf '%s\n' "$body" | grep -nE 'systemctl (start|restart)|compose up -d' | head -1 | cut -d: -f1)
  { [ -n "$g" ] && [ -n "$c" ] && [ -n "$s" ] && [ "$g" -lt "$c" ] && [ "$c" -lt "$s" ]; } || up_ok=0
done
if [ "$up_ok" = 1 ] \
   && grep -q '"$creds" install \\$' insforge-ctl \
   && grep -q '|| echo "warning: insforge-aws-creds install failed' insforge-ctl; then
  ok "insforge-ctl up/restart: guard, then creds, then start; install failure only warns"
else bad "insforge-ctl wiring of ensure_aws_creds"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
