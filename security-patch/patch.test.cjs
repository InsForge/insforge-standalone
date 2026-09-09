/**
 * node security-patch/patch.test.cjs
 *
 * Drives the gate against a stub application, so a change to the patch that stops
 * rejecting a forged identity, or starts rejecting a real one, fails here.
 */
process.env.JWT_SECRET = 'test-project-secret';
process.env.PROJECT_ID = 'project-under-test';
require('./insforge-security-patch.cjs');

const http = require('http');
const crypto = require('crypto');

const b64url = (b) => Buffer.from(b).toString('base64').replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
function sign(claims, secret = 'test-project-secret') {
  const h = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const p = b64url(JSON.stringify(claims));
  const s = crypto.createHmac('sha256', secret).update(h + '.' + p).digest('base64')
    .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
  return `${h}.${p}.${s}`;
}

const STATE = 'instance-state-jwt';
const SID = crypto.createHash('sha256').update(STATE).digest('hex');
const IDENTITY = { providerId: '42', email: 'victim@example.com', name: 'Victim' };
const now = () => Math.floor(Date.now() / 1000);
const claims = (o = {}) => ({ type: 'shared_oauth_identity', projectId: 'project-under-test',
  provider: 'github', sid: SID, identity: IDENTITY, jti: crypto.randomUUID(),
  iat: now(), exp: now() + 120, ...o });

// The "application" underneath: records what URL it was handed.
let seen = null;
const server = http.createServer((req, res) => { seen = req.url; res.writeHead(200); res.end('APP'); });

function get(path, method = 'GET') {
  return new Promise((resolve) => {
    const req = http.request({ port: 18080, path, method }, (res) => {
      let body = ''; res.on('data', (c) => body += c);
      res.on('end', () => resolve({ status: res.statusCode, body, patch: res.headers['x-insforge-security-patch'] }));
    });
    req.end();
  });
}

const cb = (qs) => `/api/auth/oauth/shared/callback/${STATE}?${qs}`;
const forged = Buffer.from(JSON.stringify({ providerId: 'x', email: 'admin@victim.com' })).toString('base64');

server.listen(18080, async () => {
  const results = [];
  const check = (name, pass, extra = '') => results.push(`${pass ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);

  let r = await get('/api/database/advance/rawsql/unrestricted', 'POST');
  check('rawsql/unrestricted is banned', r.status === 403, `status=${r.status}`);

  r = await get('/api/database/advance/rawsql', 'POST');
  check('restricted rawsql still reaches the app', r.status === 200 && r.body === 'APP');

  seen = null;
  r = await get(cb(`success=true&payload=${forged}`));
  check('forged payload with no token is rejected', r.status === 401 && seen === null, `status=${r.status}`);

  seen = null;
  const valid = sign(claims());
  r = await get(cb(`success=true&payload=${forged}&token=${valid}`));
  const rewritten = seen && JSON.parse(Buffer.from(new URL(seen, 'http://x').searchParams.get('payload'), 'base64').toString());
  check('valid assertion passes through', r.status === 200 && r.body === 'APP');
  check('forged payload is overwritten with the signed identity',
    !!rewritten && rewritten.email === 'victim@example.com', JSON.stringify(rewritten));

  seen = null;
  r = await get(cb(`success=true&token=${valid}`));
  check('replay of the same assertion is rejected', r.status === 401 && seen === null, `status=${r.status}`);

  for (const [name, c, secret] of [
    ['wrong project', claims({ projectId: 'someone-else' })],
    ['wrong login attempt', claims({ sid: 'deadbeef' })],
    ['wrong type', claims({ type: 'cloud_backend' })],
    ['carries a subject', claims({ sub: 'user-1' })],
    ['expired', claims({ exp: now() - 5 })],
    ['lifetime far in the future', claims({ exp: now() + 86400 })],
    ['signed with another secret', claims(), 'not-our-secret'],
  ]) {
    seen = null;
    r = await get(cb(`success=true&token=${sign(c, secret)}`));
    check(`rejected: ${name}`, r.status === 401 && seen === null, `status=${r.status}`);
  }

  seen = null;
  r = await get(cb('success=false&error=access_denied'));
  check('provider error path still reaches the app', r.status === 200 && seen !== null);

  r = await get('/api/health');
  check('health advertises the patch', r.patch === '1', `header=${r.patch}`);

  console.log(results.join('\n'));
  console.log(results.some((x) => x.startsWith('FAIL')) ? '\nRESULT: FAILURES' : '\nRESULT: ALL PASS');
  server.close();
});
