/**
 * Microsoft Teams Webhook Handler for {ClientName}
 *
 * A Node.js Express app that bridges Microsoft Bot Framework to
 * the Salesforce Agentforce Agent API. Receives Teams messages,
 * routes them to your agent, and sends rich responses back.
 *
 * Deployable to: Heroku, Railway, Azure App Service, or any Node.js host.
 *
 * Environment variables required (see .env.example):
 *   MICROSOFT_APP_ID, MICROSOFT_APP_PASSWORD,
 *   SF_LOGIN_URL, SF_CLIENT_ID, SF_CLIENT_SECRET, SF_AGENT_ID
 */

const express = require('express');
const jwt = require('jsonwebtoken');
const jwksRsa = require('jwks-rsa');
const app = express();
const PORT = process.env.PORT || 3978;

// Parse JSON bodies from Bot Framework
app.use(express.json());

// ─── CONFIGURATION (from environment variables) ──────────────────────────────
// These are loaded from environment variables — never hardcoded.
const CONFIG = {
    microsoftAppId: process.env.MICROSOFT_APP_ID,
    microsoftAppPassword: process.env.MICROSOFT_APP_PASSWORD,
    sfLoginUrl: process.env.SF_LOGIN_URL || 'https://login.salesforce.com',
    sfClientId: process.env.SF_CLIENT_ID,
    sfClientSecret: process.env.SF_CLIENT_SECRET,
    sfAgentId: process.env.SF_AGENT_ID,
    surfaceId: '{surfaceId}',
};

// ─── SESSION MANAGEMENT ──────────────────────────────────────────────────────
// In-memory session store. Maps conversation.id → session data.
// Sessions expire after 30 minutes of inactivity.
// For production, replace with Redis for persistence across restarts.
const sessions = new Map();
const SESSION_TTL_MS = 30 * 60 * 1000; // 30 minutes

// Salesforce OAuth token (cached, refreshed when expired)
let sfAccessToken = null;
let sfInstanceUrl = null;
let sfTokenExpiry = 0;

// Bot Framework token for sending replies (cached, refreshed when expired)
let botToken = null;
let botTokenExpiry = 0;

// JWKS client for validating inbound Bot Framework tokens
const jwksClient = jwksRsa({
    jwksUri: 'https://login.botframework.com/v1/.well-known/keys',
    cache: true,
    cacheMaxAge: 86400000, // 24 hours
});

// ─── HEALTH CHECK ────────────────────────────────────────────────────────────
app.get('/', (req, res) => {
    res.json({ status: 'ok', service: '{ClientName} Teams Webhook' });
});

// ─── POST /api/messages — INCOMING TEAMS MESSAGES ────────────────────────────
// The Bot Framework sends a POST for every message or event from Teams.
// We validate the JWT, extract the message, process it, and reply.
app.post('/api/messages', async (req, res) => {
    try {
        // Validate the inbound JWT token from Bot Framework
        const authHeader = req.headers.authorization || '';
        await validateBotFrameworkToken(authHeader);

        const activity = req.body;

        // Only process message activities with text content
        if (activity.type !== 'message' || !activity.text) {
            // Acknowledge non-message activities (e.g., conversationUpdate)
            return res.status(200).json({});
        }

        const conversationId = activity.conversation?.id;
        const userText = activity.text.trim();
        const serviceUrl = activity.serviceUrl;

        console.log(`[Message] From: ${conversationId}, Text: "${userText}"`);

        // Respond 200 immediately so Bot Framework doesn't retry
        res.status(200).json({});

        // Process the message asynchronously
        await processMessage(activity, conversationId, userText, serviceUrl);

    } catch (error) {
        if (error.name === 'TokenValidationError') {
            console.warn('[Auth] Token validation failed:', error.message);
            if (!res.headersSent) {
                return res.status(401).json({ error: 'Unauthorized' });
            }
            return;
        }

        console.error('[Error] Processing message:', error.message);
        if (!res.headersSent) {
            res.status(200).json({}); // Still return 200 to prevent retries
        }

        // Attempt to send a friendly error message back to Teams
        try {
            const activity = req.body;
            if (activity?.serviceUrl && activity?.conversation?.id) {
                await sendToTeams(activity.serviceUrl, activity.conversation.id, {
                    type: 'message',
                    text: "I'm having trouble right now. Please try again.",
                });
            }
        } catch (sendError) {
            console.error('[Error] Sending error message:', sendError.message);
        }
    }
});

// ─── MESSAGE PROCESSING ─────────────────────────────────────────────────────
// Orchestrates the full message flow: session → agent → reply.
async function processMessage(activity, conversationId, userText, serviceUrl) {
    try {
        // Get or create a session for this conversation
        const session = await getOrCreateSession(conversationId);

        // Send the message to the Agentforce Agent API
        const agentResponse = await callAgentAPI(session, userText);

        // Translate the agent's response to Teams format and send it
        const teamsMessages = translateToTeams(agentResponse);

        for (const msg of teamsMessages) {
            await sendToTeams(serviceUrl, conversationId, msg);
        }

        // Update session activity timestamp
        session.lastActivity = Date.now();

    } catch (error) {
        console.error('[Error] Processing message:', error.message);
        await sendToTeams(serviceUrl, conversationId, {
            type: 'message',
            text: "I'm having trouble right now. Please try again.",
        });
    }
}

// ─── TOKEN VALIDATION ────────────────────────────────────────────────────────
// Validates the JWT sent by Bot Framework on every incoming request.
// Uses Microsoft's published OpenID metadata and JWKS keys.
async function validateBotFrameworkToken(authHeader) {
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
        const err = new Error('Missing or malformed Authorization header');
        err.name = 'TokenValidationError';
        throw err;
    }

    const token = authHeader.substring(7);

    // Decode the header to get the key ID (kid)
    const decoded = jwt.decode(token, { complete: true });
    if (!decoded || !decoded.header || !decoded.header.kid) {
        const err = new Error('Unable to decode token header');
        err.name = 'TokenValidationError';
        throw err;
    }

    // Get the signing key from Microsoft's JWKS endpoint
    const key = await getSigningKey(decoded.header.kid);

    // Verify the token
    try {
        jwt.verify(token, key, {
            issuer: 'https://api.botframework.com',
            audience: CONFIG.microsoftAppId,
            algorithms: ['RS256'],
        });
    } catch (verifyError) {
        const err = new Error(`Token verification failed: ${verifyError.message}`);
        err.name = 'TokenValidationError';
        throw err;
    }
}

// Gets a signing key from the JWKS endpoint by key ID
function getSigningKey(kid) {
    return new Promise((resolve, reject) => {
        jwksClient.getSigningKey(kid, (err, key) => {
            if (err) {
                const error = new Error(`Failed to get signing key: ${err.message}`);
                error.name = 'TokenValidationError';
                return reject(error);
            }
            resolve(key.getPublicKey());
        });
    });
}

// ─── SESSION MANAGEMENT ──────────────────────────────────────────────────────
// Each Teams conversation gets its own Agent API session.
// Sessions expire after 30 minutes of inactivity.
async function getOrCreateSession(conversationId) {
    // Check for existing active session
    const existing = sessions.get(conversationId);
    if (existing && (Date.now() - existing.lastActivity) < SESSION_TTL_MS) {
        return existing;
    }

    // Session expired or doesn't exist — create a new one
    console.log(`[Session] Creating new session for ${conversationId}`);

    // Ensure we have a valid Salesforce token
    await ensureSfToken();

    // Create a new Agent API session
    const sessionResponse = await fetch(
        `${sfInstanceUrl}/einstein/ai-agent/v1/sessions`,
        {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${sfAccessToken}`,
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                externalSessionKey: `teams-${conversationId}-${Date.now()}`,
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

    sessions.set(conversationId, session);
    return session;
}

// ─── SALESFORCE OAUTH ────────────────────────────────────────────────────────
// Gets an OAuth token using Client Credentials flow (ECA).
// The token is cached and refreshed when it expires.
async function ensureSfToken() {
    // If we have a valid token, use it
    if (sfAccessToken && Date.now() < sfTokenExpiry) return;

    console.log('[Auth] Refreshing Salesforce access token');

    const tokenUrl = `${CONFIG.sfLoginUrl}/services/oauth2/token`;

    const response = await fetch(tokenUrl, {
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
    // Expire 5 minutes early to avoid edge cases
    sfTokenExpiry = Date.now() + (data.expires_in ? (data.expires_in - 300) * 1000 : 3300000);
}

// ─── BOT FRAMEWORK AUTH ──────────────────────────────────────────────────────
// Gets a token to send replies back to Teams.
// POST to Microsoft's OAuth endpoint with the bot's credentials.
async function ensureBotToken() {
    // If we have a valid token, use it
    if (botToken && Date.now() < botTokenExpiry) return;

    console.log('[Auth] Refreshing Bot Framework token');

    const response = await fetch(
        'https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token',
        {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({
                grant_type: 'client_credentials',
                client_id: CONFIG.microsoftAppId,
                client_secret: CONFIG.microsoftAppPassword,
                scope: 'https://api.botframework.com/.default',
            }),
        }
    );

    if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Bot Framework auth failed: ${response.status} ${errorText}`);
    }

    const data = await response.json();
    botToken = data.access_token;
    // Expire 5 minutes early to avoid edge cases
    botTokenExpiry = Date.now() + ((data.expires_in - 300) * 1000);
}

// ─── AGENT API CALL ──────────────────────────────────────────────────────────
// Sends the user's message to the Agentforce Agent API and returns the response.
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

// ─── RESPONSE FORMAT TRANSLATION ─────────────────────────────────────────────
// This is the core translation function. It converts the Agent API's structured
// response into Bot Framework Activity format for Teams.
//
// Supported mappings:
//   TeamsButtons    → Adaptive Card with Action.Submit buttons
//   TeamsChoiceSet  → Adaptive Card with Input.ChoiceSet dropdown
//   TeamsHeroCard   → Hero Card attachment
//   TeamsCarousel   → Multiple attachments (carousel)
//   Plain text      → Simple text message
function translateToTeams(agentResponse) {
    const messages = [];

    // The Agent API returns messages in a 'messages' array
    const agentMessages = agentResponse?.messages || [];

    for (const msg of agentMessages) {
        if (msg.type === 'Text') {
            // Check if the text is actually a structured response format
            const structured = tryParseStructured(msg.text);
            if (structured) {
                messages.push(...translateStructuredResponse(structured));
            } else {
                // Plain text — send as regular Teams text message
                messages.push({ type: 'message', text: msg.text });
            }
        } else if (msg.type === 'RichContent' && msg.content) {
            messages.push(...translateStructuredResponse(msg.content));
        }
    }

    // Fallback if no messages generated
    if (messages.length === 0) {
        messages.push({
            type: 'message',
            text: 'I processed your request but have nothing to display.',
        });
    }

    return messages;
}

// Attempts to parse text as structured response JSON
function tryParseStructured(text) {
    try {
        const parsed = JSON.parse(text);
        if (parsed && (parsed.type || parsed.responseFormatType)) {
            return parsed;
        }
    } catch {
        // Not JSON — that's fine, it's plain text
    }
    return null;
}

// Routes a structured response to the appropriate builder
function translateStructuredResponse(structured) {
    const responseType = structured.type || structured.responseFormatType;

    switch (responseType) {
        case 'TeamsButtons':
            return [buildAdaptiveCardButtons(structured)];
        case 'TeamsChoiceSet':
            return [buildAdaptiveCardChoiceSet(structured)];
        case 'TeamsHeroCard':
            return [buildHeroCard(structured)];
        case 'TeamsCarousel':
            return [buildCarousel(structured)];
        default:
            // Unknown format — extract text and send as plain message
            const bodyText = structured.body || structured.text || JSON.stringify(structured);
            return [{ type: 'message', text: bodyText }];
    }
}

// ─── MESSAGE BUILDERS ────────────────────────────────────────────────────────

// Builds an Adaptive Card with Action.Submit buttons
function buildAdaptiveCardButtons(data) {
    const actions = (data.buttons || []).map(btn => ({
        type: 'Action.Submit',
        title: btn.title,
        data: { value: btn.id || btn.title },
    }));

    const card = {
        type: 'AdaptiveCard',
        $schema: 'http://adaptivecards.io/schemas/adaptive-card.json',
        version: '1.4',
        body: [
            { type: 'TextBlock', text: data.body || '', wrap: true },
        ],
        actions,
    };

    // Add header if present
    if (data.header) {
        card.body.unshift({
            type: 'TextBlock',
            text: data.header,
            weight: 'Bolder',
            size: 'Medium',
        });
    }

    return {
        type: 'message',
        attachments: [{
            contentType: 'application/vnd.microsoft.card.adaptive',
            content: card,
        }],
    };
}

// Builds an Adaptive Card with Input.ChoiceSet dropdown
function buildAdaptiveCardChoiceSet(data) {
    const choices = (data.choices || []).map(choice => ({
        title: choice.title,
        value: choice.id || choice.title,
    }));

    const card = {
        type: 'AdaptiveCard',
        $schema: 'http://adaptivecards.io/schemas/adaptive-card.json',
        version: '1.4',
        body: [
            { type: 'TextBlock', text: data.body || '', wrap: true },
            {
                type: 'Input.ChoiceSet',
                id: 'userChoice',
                style: 'compact',
                choices,
            },
        ],
        actions: [
            {
                type: 'Action.Submit',
                title: data.submitLabel || 'Submit',
            },
        ],
    };

    // Add header if present
    if (data.header) {
        card.body.unshift({
            type: 'TextBlock',
            text: data.header,
            weight: 'Bolder',
            size: 'Medium',
        });
    }

    return {
        type: 'message',
        attachments: [{
            contentType: 'application/vnd.microsoft.card.adaptive',
            content: card,
        }],
    };
}

// Builds a Hero Card attachment
function buildHeroCard(data) {
    const heroCard = {
        title: data.title || '',
        subtitle: data.subtitle || '',
        text: data.text || '',
    };

    if (data.imageUrl) {
        heroCard.images = [{ url: data.imageUrl }];
    }

    if (data.buttons && data.buttons.length > 0) {
        heroCard.buttons = data.buttons.map(btn => ({
            type: 'messageBack',
            title: btn.title,
            text: btn.id || btn.title,
            value: btn.id || btn.title,
        }));
    }

    return {
        type: 'message',
        attachments: [{
            contentType: 'application/vnd.microsoft.card.hero',
            content: heroCard,
        }],
    };
}

// Builds a carousel of Hero Cards (multiple attachments)
function buildCarousel(data) {
    const cards = data.cards || [];

    const attachments = cards.map(card => {
        const heroCard = {
            title: card.title || '',
            subtitle: card.subtitle || '',
            text: card.description || '',
        };

        if (card.imageUrl) {
            heroCard.images = [{ url: card.imageUrl }];
        }

        if (card.buttons && card.buttons.length > 0) {
            heroCard.buttons = card.buttons.map(btn => ({
                type: 'messageBack',
                title: btn.title,
                text: btn.id || btn.title,
                value: btn.id || btn.title,
            }));
        }

        return {
            contentType: 'application/vnd.microsoft.card.hero',
            content: heroCard,
        };
    });

    return {
        type: 'message',
        attachmentLayout: 'carousel',
        attachments,
    };
}

// ─── SEND TO TEAMS ───────────────────────────────────────────────────────────
// Posts a formatted message back to Teams via Bot Framework REST API.
async function sendToTeams(serviceUrl, conversationId, messageContent) {
    await ensureBotToken();

    // Normalize service URL (remove trailing slash)
    const baseUrl = serviceUrl.replace(/\/$/, '');
    const url = `${baseUrl}/v3/conversations/${conversationId}/activities`;

    const response = await fetch(url, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${botToken}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify(messageContent),
    });

    if (!response.ok) {
        const errorText = await response.text();
        console.error(`[Teams API] Send failed (${response.status}): ${errorText}`);
    } else {
        console.log(`[Teams API] Message sent to ${conversationId}`);
    }
}

// ─── SESSION CLEANUP ─────────────────────────────────────────────────────────
// Clean up expired sessions every 10 minutes to prevent memory leaks
setInterval(() => {
    const now = Date.now();
    let cleaned = 0;
    for (const [convId, session] of sessions) {
        if (now - session.lastActivity > SESSION_TTL_MS) {
            sessions.delete(convId);
            cleaned++;
        }
    }
    if (cleaned > 0) {
        console.log(`[Cleanup] Removed ${cleaned} expired session(s)`);
    }
}, 10 * 60 * 1000);

// ─── START SERVER ────────────────────────────────────────────────────────────
app.listen(PORT, () => {
    console.log(`[Server] {ClientName} Teams webhook running on port ${PORT}`);
    console.log(`[Server] Messaging endpoint: http://localhost:${PORT}/api/messages`);

    // Validate that required env vars are set
    const required = ['MICROSOFT_APP_ID', 'MICROSOFT_APP_PASSWORD',
                      'SF_CLIENT_ID', 'SF_CLIENT_SECRET', 'SF_AGENT_ID'];
    const missing = required.filter(key => !process.env[key]);
    if (missing.length > 0) {
        console.warn(`[Warning] Missing environment variables: ${missing.join(', ')}`);
        console.warn('[Warning] The webhook will start but will fail to process messages.');
    }
});
