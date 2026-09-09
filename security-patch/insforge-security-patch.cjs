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
const SHARED_CALLBACK_SEGMENTS = ['api', 'auth', 'oauth', 'shared', 'callback'];
const BANNED_SQL_SEGMENTS = ['api', 'database', 'advance', 'rawsql', 'unrestricted'];
const HEALTH_SEGMENTS = ['api', 'health'];

const consumedAssertions = new Map();

/**
 * Express routes case-insensitively and tolerates a trailing slash, so the gate has
 * to match the same spellings the router does or a capital letter walks past it.
 * Segments are compared folded but returned raw: the state is a JWT and case matters.
 */
function pathSegments(requestUrl) {
  return String(requestUrl || '').split('?')[0].split('/').filter(Boolean);
}

function matchesRoute(segments, route) {
  return (
    segments.length === route.length &&
    route.every((part, index) => segments[index].toLowerCase() === part)
  );
}

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

  // Without this a caller can hold a state minted for one provider and have the
  // cloud sign an identity from another, which the application then stores under
  // the state's provider.
  const state = verifyHs256(rawState, secret);
  if (!state || state.provider !== payload.provider) {
    return 'identity assertion is for a different provider than the login attempt';
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

/**
 * Send a rejected login back where the application would have sent it. The state
 * is signed by this instance, so the target it names already passed the redirect
 * allowlist when the flow started.
 */
function refuseCallback(res, rawState) {
  // Without a secret there is nothing to verify the state against, and treating an
  // unverified one as a redirect target would make this an open redirect.
  const secret = process.env.JWT_SECRET;
  const state = secret ? verifyHs256(rawState, secret) : null;
  if (state && typeof state.redirectUri === 'string') {
    try {
      const target = new URL(state.redirectUri);
      target.searchParams.set('error', 'OAuth Authentication Failed');
      res.writeHead(302, { Location: target.toString() });
      res.end();
      return;
    } catch (error) {
      // Unusable redirect target; fall through to the plain refusal.
    }
  }
  refuse(res, 401, 'OAuth Authentication Failed');
}

function handleRequest(req, res) {
  const method = (req.method || 'GET').toUpperCase();
  const segments = pathSegments(req.url);

  if (matchesRoute(segments, BANNED_SQL_SEGMENTS)) {
    console.warn('[security-patch] refused unrestricted SQL execution');
    refuse(res, 403, 'Unrestricted SQL execution is disabled on this project.');
    return true;
  }

  if (matchesRoute(segments, HEALTH_SEGMENTS)) {
    res.setHeader('X-InsForge-Security-Patch', PATCH_VERSION);
    return false;
  }

  if (method !== 'GET' || !matchesRoute(segments.slice(0, -1), SHARED_CALLBACK_SEGMENTS)) {
    return false;
  }

  const rawState = segments[segments.length - 1];
  const reason = gateSharedCallback(req, rawState);
  if (reason) {
    console.warn('[security-patch] rejected shared OAuth callback:', reason);
    refuseCallback(res, rawState);
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
