/**
 * Auth Middleware for {ClientName} Portal Proxy
 *
 * Validates end-user JWT tokens against a configured IdP (Auth0, Okta, or
 * Salesforce Identity). Uses JWKS for key rotation support.
 *
 * Configuration (environment variables):
 *   AUTH_JWKS_URI   — JWKS endpoint for your IdP
 *   AUTH_ISSUER     — Expected token issuer
 *   AUTH_AUDIENCE   — Expected token audience (your app's client ID)
 *   ALLOW_ANONYMOUS — Set to "true" for local dev only (skips validation)
 *
 * Common IdP configurations:
 *   Auth0:   AUTH_JWKS_URI=https://YOUR_DOMAIN.auth0.com/.well-known/jwks.json
 *            AUTH_ISSUER=https://YOUR_DOMAIN.auth0.com/
 *            AUTH_AUDIENCE=your-api-identifier
 *
 *   Okta:    AUTH_JWKS_URI=https://YOUR_DOMAIN.okta.com/oauth2/default/v1/keys
 *            AUTH_ISSUER=https://YOUR_DOMAIN.okta.com/oauth2/default
 *            AUTH_AUDIENCE=api://default
 *
 *   SF Identity: AUTH_JWKS_URI=https://YOUR_ORG.my.salesforce.com/id/keys
 *                AUTH_ISSUER=https://YOUR_ORG.my.salesforce.com
 *                AUTH_AUDIENCE=your-connected-app-consumer-key
 */

const jwt = require('jsonwebtoken');
const jwksRsa = require('jwks-rsa');

let jwksClient = null;

function getJwksClient() {
    if (!jwksClient) {
        const jwksUri = process.env.AUTH_JWKS_URI;
        if (!jwksUri) {
            throw new Error('AUTH_JWKS_URI environment variable is required');
        }
        jwksClient = jwksRsa({
            jwksUri,
            cache: true,
            cacheMaxAge: 86400000, // 24 hours
            rateLimit: true,
            jwksRequestsPerMinute: 10,
        });
    }
    return jwksClient;
}

function getSigningKey(kid) {
    return new Promise((resolve, reject) => {
        getJwksClient().getSigningKey(kid, (err, key) => {
            if (err) return reject(err);
            resolve(key.getPublicKey());
        });
    });
}

async function authMiddleware(req, res, next) {
    // Local dev bypass — NEVER enable in production
    if (process.env.ALLOW_ANONYMOUS === 'true') {
        req.user = { sub: 'anonymous-dev-user' };
        return next();
    }

    const authHeader = req.headers.authorization || '';
    if (!authHeader.startsWith('Bearer ')) {
        return res.status(401).json({
            error: 'unauthorized',
            message: 'Missing or malformed Authorization header',
        });
    }

    const token = authHeader.substring(7);

    try {
        const decoded = jwt.decode(token, { complete: true });
        if (!decoded || !decoded.header || !decoded.header.kid) {
            return res.status(401).json({
                error: 'unauthorized',
                message: 'Unable to decode token',
            });
        }

        const key = await getSigningKey(decoded.header.kid);

        const verified = jwt.verify(token, key, {
            issuer: process.env.AUTH_ISSUER,
            audience: process.env.AUTH_AUDIENCE,
            algorithms: ['RS256'],
        });

        req.user = verified;
        next();

    } catch (error) {
        console.warn('[Auth] Token validation failed:', error.message);

        if (error.name === 'TokenExpiredError') {
            return res.status(401).json({
                error: 'token_expired',
                message: 'Your session has expired. Please log in again.',
            });
        }

        return res.status(401).json({
            error: 'unauthorized',
            message: 'Invalid token',
        });
    }
}

module.exports = { authMiddleware };
