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
export INSFORGE_AWS_CREDS_DIR=$OUT FAKE_STATE=$WORK/imds.json
pass=0
fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

cat > "$STUBS/id" <<'STUB'
#!/bin/bash
echo 0
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

# 3. files are readable by a non-root container user and nothing is left behind.
if [ "$(stat -c %a "$OUT/credentials.json" 2>/dev/null || stat -f %Lp "$OUT/credentials.json")" = 644 ] \
   && ! compgen -G "$OUT/.*.??????" >/dev/null; then
  ok "credentials.json is 0644 and no temp files remain"
else bad "permissions/temp files: $(ls -la "$OUT")"; fi

# 4. a rotated role is picked up on the next refresh.
creds_json ASIASECOND Success "$future" > "$FAKE_STATE"
"$CREDS" refresh >/dev/null 2>&1
if grep -q ASIASECOND "$OUT/credentials.json"; then ok "refresh picks up rotated credentials"; else bad "rotation not picked up"; fi

# 5. an IMDS error leaves the last good file in place and fails loudly.
creds_json ASIABROKEN Failure "$future" > "$FAKE_STATE"
if ! "$CREDS" refresh >/dev/null 2>&1 && grep -q ASIASECOND "$OUT/credentials.json"; then
  ok "IMDS failure exits non-zero and keeps the last good credentials"
else bad "IMDS failure handling"; fi

# 6. status: OK while valid, failing once expired or missing.
if "$CREDS" status >/dev/null 2>&1; then ok "status OK on valid credentials"; else bad "status on valid credentials"; fi
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

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
