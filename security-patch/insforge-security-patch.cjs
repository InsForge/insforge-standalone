'use strict';

/**
 * Security patch for project instances running an InsForge image from before the
 * shared-OAuth fix. Loaded into the insforge container with
 * NODE_OPTIONS=--require, so it gates requests ahead of the application's own
 * router and needs nothing from the image it is patching.
 *
 * It closes two holes:
 *
 *   1. GET /api/auth/oauth/shared/callback/:state accepted a base64 `payload`
 *      query parameter as authenticated identity, so anyone could mint a session
 *      for any email. The gate requires a cloud-signed assertion and overwrites
 *      `payload` with the identity that assertion carries, so the unpatched
 *      application below reads verified data through its existing code path.
 *
 *   2. POST /api/database/advance/rawsql/unrestricted executes SQL as the
 *      database superuser. Refused outright.
 *
 * Pure node builtins: it is required before the application's node_modules are
 * on any resolution path, and it has to work on every image version in the fleet.
 */

const crypto = require('crypto');
const http = require('http');

const PATCH_VERSION = '1';
const IDENTITY_TOKEN_TYPE = 'shared_oauth_identity';
// Bounds the replay window and the consumed-assertion map when an assertion
// arrives with a longer life than the cloud signs; loose enough for clock skew.
const MAX_IDENTITY_LIFETIME_MS = 10 * 60 * 1000;
const SHARED_CALLBACK_PATH = /^\/api\/auth\/oauth\/shared\/callback\/([^/?#]+)/;
const BANNED_SQL_PATH = '/api/database/advance/rawsql/unrestricted';
const HEALTH_PATH = '/api/health';

const consumedAssertions = new Map();

function base64UrlToBuffer(value) {
  return Buffer.from(String(value).replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

/**
 * Verify an HS256 JWT against the project's own secret. Only HS256 is accepted and
 * the signature is always recomputed as HMAC, so a token cannot pick its own algorithm.
 */
function verifyHs256(token, secret) {
  const parts = String(token).split('.');
  if (parts.length !== 3) {
    return null;
  }

  const expected = crypto.createHmac('sha256', secret).update(parts[0] + '.' + parts[1]).digest();
  const supplied = base64UrlToBuffer(parts[2]);
  if (supplied.length !== expected.length || !crypto.timingSafeEqual(supplied, expected)) {
    return null;
  }

  try {
    const header = JSON.parse(base64UrlToBuffer(parts[0]).toString('utf8'));
    if (!header || header.alg !== 'HS256') {
      return null;
    }
    return JSON.parse(base64UrlToBuffer(parts[1]).toString('utf8'));
  } catch (error) {
    return null;
  }
}

function consume(jti, expiresAt) {
  const now = Date.now();
  for (const [seen, seenExpiresAt] of consumedAssertions) {
    if (seenExpiresAt <= now) {
      consumedAssertions.delete(seen);
    }
  }
  if (consumedAssertions.has(jti)) {
    return false;
  }
  consumedAssertions.set(jti, expiresAt);
  return true;
}

/**
 * Returns null when the request may proceed, or a rejection reason.
 * Rewrites `payload` on the request so the application reads the verified identity.
 */
function gateSharedCallback(req, rawState) {
  const secret = process.env.JWT_SECRET;
  const projectId = process.env.PROJECT_ID;
  if (!secret || !projectId) {
    return 'instance is missing JWT_SECRET or PROJECT_ID';
  }

  let url;
  try {
    url = new URL(req.url, 'http://insforge.invalid');
  } catch (error) {
    return 'callback url could not be parsed';
  }

  // The provider-error path carries no identity and mints no session; the
  // application only redirects with the error, so leave it alone.
  if (url.searchParams.get('success') !== 'true') {
    return null;
  }

  const token = url.searchParams.get('token');
  if (!token) {
    return 'no cloud-signed identity assertion';
  }

  const payload = verifyHs256(token, secret);
  if (!payload) {
    return 'identity assertion is not signed for this project';
  }
  if (payload.type !== IDENTITY_TOKEN_TYPE) {
    return 'signed token is not a shared OAuth identity assertion';
  }
  if (payload.sub !== undefined) {
    return 'identity assertion carries a subject';
  }
  if (payload.projectId !== projectId) {
    return 'identity assertion is for a different project';
  }
  if (payload.sid !== crypto.createHash('sha256').update(rawState).digest('hex')) {
    return 'identity assertion is for a different login attempt';
  }

  const expiresAt = typeof payload.exp === 'number' ? payload.exp * 1000 : 0;
  if (!expiresAt || expiresAt <= Date.now()) {
    return 'identity assertion has expired';
  }
  if (expiresAt > Date.now() + MAX_IDENTITY_LIFETIME_MS) {
    return 'identity assertion outlives its flow';
  }

  const identity = payload.identity;
  if (!identity || typeof identity !== 'object' || Array.isArray(identity)) {
    return 'identity assertion carries no identity';
  }
  if (typeof payload.jti !== 'string' || !payload.jti || !consume(payload.jti, expiresAt)) {
    return 'identity assertion was already used';
  }

  url.searchParams.set('payload', Buffer.from(JSON.stringify(identity)).toString('base64'));
  req.url = url.pathname + url.search;
  return null;
}

function refuse(res, status, message) {
  if (res.headersSent) {
    return;
  }
  const body = JSON.stringify({ error: message, statusCode: status });
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function handleRequest(req, res) {
  const method = (req.method || 'GET').toUpperCase();
  const path = String(req.url || '').split('?')[0];

  if (path === BANNED_SQL_PATH) {
    refuse(res, 403, 'Unrestricted SQL execution is disabled on this project.');
    return true;
  }

  if (path === HEALTH_PATH) {
    res.setHeader('X-InsForge-Security-Patch', PATCH_VERSION);
    return false;
  }

  if (method !== 'GET') {
    return false;
  }

  const match = SHARED_CALLBACK_PATH.exec(String(req.url || ''));
  if (!match) {
    return false;
  }

  const reason = gateSharedCallback(req, match[1]);
  if (reason) {
    console.warn('[security-patch] rejected shared OAuth callback:', reason);
    refuse(res, 401, 'OAuth Authentication Failed');
    return true;
  }

  return false;
}

const originalCreateServer = http.createServer;
http.createServer = function createServer(...args) {
  const listener = typeof args[args.length - 1] === 'function' ? args.pop() : null;
  if (!listener) {
    return originalCreateServer.apply(this, args);
  }

  return originalCreateServer.call(this, ...args, function patchedListener(req, res) {
    let handled = false;
    try {
      handled = handleRequest(req, res);
    } catch (error) {
      // A fault in the gate must not take the request path down with it. The two
      // guarded routes still fail closed: the SQL ban is checked before anything
      // that can throw, and the callback gate rejects rather than falling through.
      console.error('[security-patch] gate error:', error && error.message);
      refuse(res, 500, 'Internal Server Error');
      return;
    }
    if (!handled) {
      listener.call(this, req, res);
    }
  });
};

console.log('[security-patch] active, version ' + PATCH_VERSION);
