/**
 * Auth Middleware Tests
 *
 * Validates JWT authentication against JWKS for Auth0, Okta, and SF Identity.
 * Uses a local RSA key pair to simulate IdP-issued tokens.
 *
 * Run: npm test
 * Requires: npm install --save-dev jest node-jose
 */

const { createServer } = require('http');
const express = require('express');
const jose = require('node-jose');
const jwt = require('jsonwebtoken');

// We need to mock the JWKS server before requiring auth middleware
let jwksServer;
let jwksPort;
let rsaKey;
let publicJwks;

beforeAll(async () => {
    // Generate an RSA key pair for signing test tokens
    const keystore = jose.JWK.createKeyStore();
    rsaKey = await keystore.generate('RSA', 2048, { alg: 'RS256', use: 'sig', kid: 'test-key-1' });
    publicJwks = keystore.toJSON();

    // Start a local JWKS server
    const app = express();
    app.get('/.well-known/jwks.json', (req, res) => {
        res.json(publicJwks);
    });

    await new Promise(resolve => {
        jwksServer = app.listen(0, () => {
            jwksPort = jwksServer.address().port;
            resolve();
        });
    });

    // Configure env vars to point at our local JWKS server
    process.env.AUTH_JWKS_URI = `http://localhost:${jwksPort}/.well-known/jwks.json`;
    process.env.AUTH_ISSUER = 'https://test-idp.example.com/';
    process.env.AUTH_AUDIENCE = 'test-api-audience';
    delete process.env.ALLOW_ANONYMOUS;
});

afterAll(async () => {
    if (jwksServer) {
        await new Promise(resolve => jwksServer.close(resolve));
    }
});

function signToken(payload, options = {}) {
    const privateKeyPem = rsaKey.toPEM(true);
    return jwt.sign(payload, privateKeyPem, {
        algorithm: 'RS256',
        keyid: 'test-key-1',
        issuer: options.issuer || 'https://test-idp.example.com/',
        audience: options.audience || 'test-api-audience',
        expiresIn: options.expiresIn || '1h',
        subject: options.sub || 'user-123',
    });
}

// Fresh require for each test suite to reset JWKS client state
function getAuthMiddleware() {
    // Clear module cache to get fresh instance
    delete require.cache[require.resolve('../auth-middleware')];
    return require('../auth-middleware').authMiddleware;
}

function createTestApp(middleware) {
    const app = express();
    app.use(express.json());
    app.get('/test', middleware, (req, res) => {
        res.json({ user: req.user });
    });
    return app;
}

async function request(app, headers = {}) {
    return new Promise((resolve, reject) => {
        const server = app.listen(0, () => {
            const port = server.address().port;
            fetch(`http://localhost:${port}/test`, { headers })
                .then(async res => {
                    const body = await res.json();
                    resolve({ status: res.status, body });
                    server.close();
                })
                .catch(err => {
                    server.close();
                    reject(err);
                });
        });
    });
}

describe('Auth Middleware', () => {
    describe('Valid tokens', () => {
        test('accepts a valid token with correct issuer and audience', async () => {
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);
            const token = signToken({ email: 'user@example.com' });

            const res = await request(app, { Authorization: `Bearer ${token}` });

            expect(res.status).toBe(200);
            expect(res.body.user.sub).toBe('user-123');
            expect(res.body.user.email).toBe('user@example.com');
        });

        test('extracts custom claims from token', async () => {
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);
            const token = signToken({
                email: 'admin@corp.com',
                'https://myapp.com/roles': ['admin'],
                org_id: 'org-456',
            });

            const res = await request(app, { Authorization: `Bearer ${token}` });

            expect(res.status).toBe(200);
            expect(res.body.user.email).toBe('admin@corp.com');
            expect(res.body.user['https://myapp.com/roles']).toEqual(['admin']);
        });
    });

    describe('Missing or malformed auth', () => {
        test('rejects request with no Authorization header', async () => {
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);

            const res = await request(app, {});

            expect(res.status).toBe(401);
            expect(res.body.error).toBe('unauthorized');
        });

        test('rejects request with non-Bearer scheme', async () => {
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);

            const res = await request(app, { Authorization: 'Basic dXNlcjpwYXNz' });

            expect(res.status).toBe(401);
            expect(res.body.error).toBe('unauthorized');
        });

        test('rejects request with empty Bearer token', async () => {
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);

            const res = await request(app, { Authorization: 'Bearer ' });

            expect(res.status).toBe(401);
        });

        test('rejects request with garbage token', async () => {
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);

            const res = await request(app, { Authorization: 'Bearer not.a.real.jwt' });

            expect(res.status).toBe(401);
        });
    });

    describe('Invalid tokens', () => {
        test('rejects token with wrong issuer', async () => {
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);
            const token = signToken({}, { issuer: 'https://wrong-issuer.com/' });

            const res = await request(app, { Authorization: `Bearer ${token}` });

            expect(res.status).toBe(401);
        });

        test('rejects token with wrong audience', async () => {
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);
            const token = signToken({}, { audience: 'wrong-audience' });

            const res = await request(app, { Authorization: `Bearer ${token}` });

            expect(res.status).toBe(401);
        });

        test('rejects expired token with specific error', async () => {
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);
            const token = signToken({}, { expiresIn: '-1h' });

            const res = await request(app, { Authorization: `Bearer ${token}` });

            expect(res.status).toBe(401);
            expect(res.body.error).toBe('token_expired');
        });

        test('rejects token signed with wrong key', async () => {
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);

            // Generate a different key and sign with it
            const wrongKeystore = jose.JWK.createKeyStore();
            const wrongKey = await wrongKeystore.generate('RSA', 2048, { alg: 'RS256', kid: 'wrong-key' });
            const wrongToken = jwt.sign(
                { sub: 'attacker' },
                wrongKey.toPEM(true),
                { algorithm: 'RS256', keyid: 'wrong-key', issuer: 'https://test-idp.example.com/', audience: 'test-api-audience' }
            );

            const res = await request(app, { Authorization: `Bearer ${wrongToken}` });

            expect(res.status).toBe(401);
        });
    });

    describe('ALLOW_ANONYMOUS mode', () => {
        test('bypasses auth when ALLOW_ANONYMOUS=true', async () => {
            process.env.ALLOW_ANONYMOUS = 'true';
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);

            const res = await request(app, {});

            expect(res.status).toBe(200);
            expect(res.body.user.sub).toBe('anonymous-dev-user');

            delete process.env.ALLOW_ANONYMOUS;
        });

        test('does NOT bypass when ALLOW_ANONYMOUS is not "true"', async () => {
            process.env.ALLOW_ANONYMOUS = 'false';
            const authMiddleware = getAuthMiddleware();
            const app = createTestApp(authMiddleware);

            const res = await request(app, {});

            expect(res.status).toBe(401);

            delete process.env.ALLOW_ANONYMOUS;
        });
    });
});

describe('IdP-specific token formats', () => {
    test('Auth0 token format (namespaced claims)', async () => {
        const authMiddleware = getAuthMiddleware();
        const app = createTestApp(authMiddleware);
        const token = signToken({
            'https://myportal.com/email': 'user@company.com',
            'https://myportal.com/roles': ['customer'],
            azp: 'client-id-123',
            scope: 'openid profile email',
        });

        const res = await request(app, { Authorization: `Bearer ${token}` });
        expect(res.status).toBe(200);
        expect(res.body.user['https://myportal.com/email']).toBe('user@company.com');
    });

    test('Okta token format (scp claim)', async () => {
        const authMiddleware = getAuthMiddleware();
        const app = createTestApp(authMiddleware);
        const token = signToken({
            uid: 'okta-user-789',
            scp: ['openid', 'profile'],
            cid: 'okta-client-id',
        });

        const res = await request(app, { Authorization: `Bearer ${token}` });
        expect(res.status).toBe(200);
        expect(res.body.user.uid).toBe('okta-user-789');
    });

    test('Salesforce Identity token format', async () => {
        const authMiddleware = getAuthMiddleware();
        const app = createTestApp(authMiddleware);
        const token = signToken({
            organization_id: '00Dxx0000001234',
            custom_attributes: { ContactId: '003xx000001234' },
        });

        const res = await request(app, { Authorization: `Bearer ${token}` });
        expect(res.status).toBe(200);
        expect(res.body.user.organization_id).toBe('00Dxx0000001234');
    });
});
