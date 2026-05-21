/**
 * In-App Portal Proxy for {ClientName}
 *
 * Express server that bridges your portal frontend to the Salesforce
 * Agentforce Agent API. Holds ECA secrets server-side, manages sessions,
 * validates end-user identity, and returns structured format responses.
 *
 * Deployable to: Heroku, Railway, AWS, or any Node.js host.
 *
 * Environment variables required (see .env.example):
 *   SF_LOGIN_URL, SF_CLIENT_ID, SF_CLIENT_SECRET, SF_AGENT_ID,
 *   AUTH_JWKS_URI, AUTH_ISSUER, AUTH_AUDIENCE,
 *   ALLOW_ANONYMOUS (optional, local dev only)
 */

const express = require('express');
const cors = require('cors');
const { authMiddleware } = require('./auth-middleware');

const app = express();
const PORT = process.env.PORT || 3001;

app.use(express.json());

// CORS — restrict to your portal's origin in production
app.use(cors({
    origin: process.env.ALLOWED_ORIGIN || 'http://localhost:5173',
    credentials: true,
}));

// ─── CONFIGURATION ──────────────────────────────────────────────────────────
const CONFIG = {
    sfLoginUrl: process.env.SF_LOGIN_URL || 'https://login.salesforce.com',
    sfClientId: process.env.SF_CLIENT_ID,
    sfClientSecret: process.env.SF_CLIENT_SECRET,
    sfAgentId: process.env.SF_AGENT_ID,
    surfaceId: '{surfaceId}',
};

// ─── SESSION MANAGEMENT ─────────────────────────────────────────────────────
// Maps authenticated user ID → Agent API session data.
// For production, replace with Redis for persistence across restarts.
const sessions = new Map();
const SESSION_TTL_MS = 30 * 60 * 1000; // 30 minutes

// Salesforce OAuth token (cached, refreshed when expired)
let sfAccessToken = null;
let sfInstanceUrl = null;
let sfTokenExpiry = 0;

// ─── HEALTH CHECK ───────────────────────────────────────────────────────────
app.get('/api/health', (req, res) => {
    res.json({ status: 'ok', service: '{ClientName} Portal Proxy' });
});

// ─── POST /api/agent/message — SEND MESSAGE TO AGENT ────────────────────────
// Authenticated endpoint. Receives user message, routes to Agent API,
// returns structured response for the frontend to render.
app.post('/api/agent/message', authMiddleware, async (req, res) => {
    try {
        const userId = req.user.sub;
        const { message } = req.body;

        if (!message || typeof message !== 'string' || message.trim().length === 0) {
            return res.status(400).json({ error: 'Message is required' });
        }

        const userText = message.trim();

        // Get or create a session for this user
        const session = await getOrCreateSession(userId);

        // Send the message to the Agent API
        const agentResponse = await callAgentAPI(session, userText);

        // Parse the response into structured formats
        const responses = parseAgentResponse(agentResponse);

        // Update session activity
        session.lastActivity = Date.now();

        res.json({ responses });

    } catch (error) {
        console.error('[Error] /api/agent/message:', error.message);

        if (error.message.includes('auth failed') || error.message.includes('401')) {
            return res.status(502).json({
                error: 'upstream_auth_failed',
                message: 'Unable to connect to the agent. Please try again.',
            });
        }

        res.status(500).json({
            error: 'agent_error',
            message: 'Something went wrong. Please try again.',
        });
    }
});

// ─── POST /api/agent/session/reset — RESET SESSION ──────────────────────────
// Lets the frontend explicitly end a conversation and start fresh.
app.post('/api/agent/session/reset', authMiddleware, async (req, res) => {
    const userId = req.user.sub;
    sessions.delete(userId);
    res.json({ status: 'reset' });
});

// ─── SESSION MANAGEMENT ─────────────────────────────────────────────────────
async function getOrCreateSession(userId) {
    const existing = sessions.get(userId);
    if (existing && (Date.now() - existing.lastActivity) < SESSION_TTL_MS) {
        return existing;
    }

    console.log(`[Session] Creating new session for user ${userId}`);

    await ensureSfToken();

    const sessionResponse = await fetch(
        `${sfInstanceUrl}/einstein/ai-agent/v1/sessions`,
        {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${sfAccessToken}`,
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                externalSessionKey: `portal-${userId}-${Date.now()}`,
                instanceConfig: {
                    endpoint: sfInstanceUrl,
                },
                streamingCapabilities: {
                    chunkTypes: ['Text'],
                },
                bypassUser: true,
            }),
        }
    );

    if (!sessionResponse.ok) {
        const errorText = await sessionResponse.text();
        throw new Error(`Failed to create agent session: ${sessionResponse.status} ${errorText}`);
    }

    const sessionData = await sessionResponse.json();

    const session = {
        agentSessionId: sessionData.sessionId,
        sequenceId: 0,
        lastActivity: Date.now(),
    };

    sessions.set(userId, session);
    return session;
}

// ─── SALESFORCE OAUTH ───────────────────────────────────────────────────────
async function ensureSfToken() {
    if (sfAccessToken && Date.now() < sfTokenExpiry) return;

    console.log('[Auth] Refreshing Salesforce access token');

    const response = await fetch(`${CONFIG.sfLoginUrl}/services/oauth2/token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
            grant_type: 'client_credentials',
            client_id: CONFIG.sfClientId,
            client_secret: CONFIG.sfClientSecret,
        }),
    });

    if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Salesforce auth failed: ${response.status} ${errorText}`);
    }

    const data = await response.json();
    sfAccessToken = data.access_token;
    sfInstanceUrl = data.instance_url;
    sfTokenExpiry = Date.now() + (data.expires_in ? (data.expires_in - 300) * 1000 : 3300000);
}

// ─── AGENT API CALL ─────────────────────────────────────────────────────────
async function callAgentAPI(session, userMessage) {
    await ensureSfToken();

    session.sequenceId += 1;

    const response = await fetch(
        `${sfInstanceUrl}/einstein/ai-agent/v1/sessions/${session.agentSessionId}/messages`,
        {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${sfAccessToken}`,
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                message: {
                    sequenceId: session.sequenceId,
                    type: 'Text',
                    text: userMessage,
                },
                variables: [],
                surfaceType: 'Custom',
                surfaceId: CONFIG.surfaceId,
            }),
        }
    );

    if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Agent API error: ${response.status} ${errorText}`);
    }

    return await response.json();
}

// ─── RESPONSE PARSING ───────────────────────────────────────────────────────
// Parses Agent API response into structured format objects for the frontend.
// The frontend renders these directly — no translation layer needed (unlike
// WhatsApp/Teams where we convert to channel-specific schemas).
function parseAgentResponse(agentResponse) {
    const responses = [];
    const agentMessages = agentResponse?.messages || [];

    for (const msg of agentMessages) {
        if (msg.type === 'Text') {
            const structured = tryParseStructured(msg.text);
            if (structured) {
                responses.push(structured);
            } else {
                responses.push({ type: 'text', content: msg.text });
            }
        } else if (msg.type === 'RichContent' && msg.content) {
            responses.push(msg.content);
        }
    }

    if (responses.length === 0) {
        responses.push({ type: 'text', content: 'I processed your request but have nothing to display.' });
    }

    return responses;
}

function tryParseStructured(text) {
    try {
        const parsed = JSON.parse(text);
        if (parsed && (parsed.type || parsed.responseFormatType)) {
            return parsed;
        }
    } catch {
        // Not JSON — plain text
    }
    return null;
}

// ─── SESSION CLEANUP ────────────────────────────────────────────────────────
setInterval(() => {
    const now = Date.now();
    let cleaned = 0;
    for (const [userId, session] of sessions) {
        if (now - session.lastActivity > SESSION_TTL_MS) {
            sessions.delete(userId);
            cleaned++;
        }
    }
    if (cleaned > 0) {
        console.log(`[Cleanup] Removed ${cleaned} expired session(s)`);
    }
}, 10 * 60 * 1000);

// ─── START SERVER ───────────────────────────────────────────────────────────
app.listen(PORT, () => {
    console.log(`[Server] {ClientName} Portal Proxy running on port ${PORT}`);

    const required = ['SF_CLIENT_ID', 'SF_CLIENT_SECRET', 'SF_AGENT_ID'];
    const missing = required.filter(key => !process.env[key]);
    if (missing.length > 0) {
        console.warn(`[Warning] Missing env vars: ${missing.join(', ')}`);
        console.warn('[Warning] The proxy will fail to authenticate with Salesforce.');
    }

    if (process.env.ALLOW_ANONYMOUS === 'true') {
        console.warn('[Warning] ALLOW_ANONYMOUS=true — auth is disabled. For local dev only.');
    }
});
