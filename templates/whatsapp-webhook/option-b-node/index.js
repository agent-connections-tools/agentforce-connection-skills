/**
 * WhatsApp Webhook Handler for {ClientName}
 *
 * A Node.js Express app that bridges Meta's WhatsApp Cloud API to
 * the Salesforce Agentforce Agent API. Receives WhatsApp messages,
 * routes them to your agent, and sends rich responses back.
 *
 * Deployable to: Heroku, Railway, Vercel, or any Node.js host.
 *
 * Environment variables required (see .env.example):
 *   META_VERIFY_TOKEN, META_ACCESS_TOKEN, META_PHONE_NUMBER_ID,
 *   SF_LOGIN_URL, SF_CLIENT_ID, SF_CLIENT_SECRET, SF_AGENT_ID
 */

const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

// Parse JSON bodies from Meta webhooks
app.use(express.json());

// ─── CONFIGURATION (from environment variables) ──────────────────────────────
// These are loaded from environment variables — never hardcoded.
const CONFIG = {
    metaVerifyToken: process.env.META_VERIFY_TOKEN,
    metaAccessToken: process.env.META_ACCESS_TOKEN,
    metaPhoneNumberId: process.env.META_PHONE_NUMBER_ID,
    sfLoginUrl: process.env.SF_LOGIN_URL || 'https://login.salesforce.com',
    sfClientId: process.env.SF_CLIENT_ID,
    sfClientSecret: process.env.SF_CLIENT_SECRET,
    sfAgentId: process.env.SF_AGENT_ID,
    surfaceId: '{surfaceId}',
};

// ─── SESSION MANAGEMENT ──────────────────────────────────────────────────────
// In-memory session store. Maps phone number → session data.
// Sessions expire after 30 minutes of inactivity.
// For production, replace with Redis for persistence across restarts.
const sessions = new Map();
const SESSION_TTL_MS = 30 * 60 * 1000; // 30 minutes

// Salesforce OAuth token (cached, refreshed when expired)
let sfAccessToken = null;
let sfInstanceUrl = null;
let sfTokenExpiry = 0;

// ─── HEALTH CHECK ────────────────────────────────────────────────────────────
app.get('/', (req, res) => {
    res.json({ status: 'ok', service: '{ClientName} WhatsApp Webhook' });
});

// ─── GET /webhook — META VERIFICATION CHALLENGE ──────────────────────────────
// When you configure the webhook URL in Meta's dashboard, Meta sends a GET
// request with a challenge. You must return the challenge if the token matches.
app.get('/webhook', (req, res) => {
    const mode = req.query['hub.mode'];
    const token = req.query['hub.verify_token'];
    const challenge = req.query['hub.challenge'];

    if (mode === 'subscribe' && token === CONFIG.metaVerifyToken) {
        console.log('[Webhook] Verification successful');
        return res.status(200).send(challenge);
    }

    console.warn('[Webhook] Verification failed — token mismatch');
    return res.status(403).send('Verification failed');
});

// ─── POST /webhook — INCOMING WHATSAPP MESSAGES ──────────────────────────────
// Meta sends a POST whenever someone messages your WhatsApp Business number.
// We respond with 200 immediately, then process the message asynchronously.
app.post('/webhook', async (req, res) => {
    // Always respond 200 to Meta immediately (they retry on non-2xx)
    res.status(200).send('OK');

    try {
        // Extract the message from Meta's nested payload
        const messageData = extractMessage(req.body);
        if (!messageData) return; // Not an actionable message (status update, etc.)

        const { phoneNumber, text } = messageData;
        console.log(`[Message] From: ${phoneNumber}, Text: "${text}"`);

        // Get or create a session for this phone number
        const session = await getOrCreateSession(phoneNumber);

        // Send the message to the Agentforce Agent API
        const agentResponse = await callAgentAPI(session, text);

        // Translate the agent's response to WhatsApp format and send it
        const whatsappMessages = translateToWhatsApp(agentResponse);

        for (const msg of whatsappMessages) {
            await sendToWhatsApp(phoneNumber, msg);
        }

        // Update session activity timestamp
        session.lastActivity = Date.now();

    } catch (error) {
        console.error('[Error] Processing message:', error.message);
        // Send a friendly error message to the user
        const phoneNumber = extractPhoneNumber(req.body);
        if (phoneNumber) {
            await sendToWhatsApp(phoneNumber, {
                type: 'text',
                text: { body: "I'm having trouble right now. Please try again." }
            });
        }
    }
});

// ─── MESSAGE EXTRACTION ──────────────────────────────────────────────────────
// Meta's webhook payload is deeply nested. This function digs in to find the
// actual message content and sender phone number.
function extractMessage(payload) {
    try {
        const entry = payload?.entry?.[0];
        const change = entry?.changes?.[0];
        const value = change?.value;
        const message = value?.messages?.[0];

        if (!message) return null; // Likely a status update, not a message

        const phoneNumber = message.from;
        let text = '';

        // Handle different message types
        switch (message.type) {
            case 'text':
                text = message.text?.body || '';
                break;
            case 'interactive':
                // User tapped a button or selected from a list (or completed a Flow)
                if (message.interactive?.type === 'button_reply') {
                    text = message.interactive.button_reply?.id || '';
                } else if (message.interactive?.type === 'list_reply') {
                    text = message.interactive.list_reply?.id || '';
                } else if (message.interactive?.type === 'nfm_reply') {
                    const responseJson = message.interactive.nfm_reply?.response_json;
                    text = responseJson ? `[Flow Response] ${responseJson}` : '';
                }
                break;
            default:
                // Unsupported type (image, audio, location, etc.)
                console.log(`[Message] Unsupported type: ${message.type}`);
                return null;
        }

        if (!text) return null;
        return { phoneNumber, text };
    } catch (error) {
        console.error('[Error] Extracting message:', error.message);
        return null;
    }
}

// Helper to extract just the phone number (for error messages)
function extractPhoneNumber(payload) {
    try {
        return payload?.entry?.[0]?.changes?.[0]?.value?.messages?.[0]?.from || null;
    } catch {
        return null;
    }
}

// ─── SESSION MANAGEMENT ──────────────────────────────────────────────────────
// Each WhatsApp phone number gets its own Agent API session.
// Sessions expire after 30 minutes of inactivity.
async function getOrCreateSession(phoneNumber) {
    // Check for existing active session
    const existing = sessions.get(phoneNumber);
    if (existing && (Date.now() - existing.lastActivity) < SESSION_TTL_MS) {
        return existing;
    }

    // Session expired or doesn't exist — create a new one
    console.log(`[Session] Creating new session for ${phoneNumber}`);

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
                externalSessionKey: `wa-${phoneNumber}-${Date.now()}`,
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

    sessions.set(phoneNumber, session);
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
// response into Meta's WhatsApp message format.
//
// Supported mappings:
//   WhatsAppButtons  → interactive.type: "button"   (up to 3 buttons)
//   WhatsAppList     → interactive.type: "list"     (sections with rows)
//   WhatsAppMedia    → type: "image" or "video"
//   WhatsAppCarousel → template with CAROUSEL component (approximated as images)
//   WhatsAppFlow     → interactive.type: "flow"     (triggers a pre-created Flow)
//   Plain text       → type: "text"
function translateToWhatsApp(agentResponse) {
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
                // Plain text — send as regular WhatsApp text message
                messages.push({ type: 'text', text: { body: msg.text } });
            }
        } else if (msg.type === 'RichContent' && msg.content) {
            messages.push(...translateStructuredResponse(msg.content));
        }
    }

    // Fallback if no messages generated
    if (messages.length === 0) {
        messages.push({
            type: 'text',
            text: { body: 'I processed your request but have nothing to display.' },
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
        case 'WhatsAppButtons':
            return [buildButtonMessage(structured)];
        case 'WhatsAppList':
            return [buildListMessage(structured)];
        case 'WhatsAppMedia':
            return [buildMediaMessage(structured)];
        case 'WhatsAppCarousel':
            return buildCarouselMessages(structured);
        case 'WhatsAppFlow':
            return [buildFlowMessage(structured)];
        default:
            // Unknown format — extract text and send as plain message
            const bodyText = structured.body || structured.text || JSON.stringify(structured);
            return [{ type: 'text', text: { body: bodyText } }];
    }
}

// ─── MESSAGE BUILDERS ────────────────────────────────────────────────────────

// Builds an interactive button message (Meta allows up to 3 buttons)
function buildButtonMessage(data) {
    const buttons = (data.buttons || []).slice(0, 3).map(btn => ({
        type: 'reply',
        reply: {
            id: btn.id,
            title: truncate(btn.title, 20),
        },
    }));

    const interactive = {
        type: 'button',
        body: { text: data.body || '' },
        action: { buttons },
    };

    if (data.header) {
        interactive.header = { type: 'text', text: data.header };
    }
    if (data.footer) {
        interactive.footer = { text: data.footer };
    }

    return { type: 'interactive', interactive };
}

// Builds an interactive list message (sections with selectable rows)
function buildListMessage(data) {
    const sections = (data.sections || []).map(section => ({
        title: section.title || '',
        rows: (section.rows || []).map(row => ({
            id: row.id,
            title: truncate(row.title, 24),
            description: truncate(row.description || '', 72),
        })),
    }));

    const interactive = {
        type: 'list',
        body: { text: data.body || '' },
        action: {
            button: truncate(data.buttonText || 'Options', 20),
            sections,
        },
    };

    if (data.header) {
        interactive.header = { type: 'text', text: data.header };
    }
    if (data.footer) {
        interactive.footer = { text: data.footer };
    }

    return { type: 'interactive', interactive };
}

// Builds a media message (image or video with optional caption)
function buildMediaMessage(data) {
    const mediaType = data.mediaType || 'image';
    const mediaObj = { link: data.url };
    if (data.caption) {
        mediaObj.caption = data.caption;
    }

    return {
        type: mediaType,
        [mediaType]: mediaObj,
    };
}

// Builds carousel as multiple image messages
// Note: Meta doesn't support native carousel in regular messages (only in templates).
// We approximate by sending each card as a separate image with caption.
function buildCarouselMessages(data) {
    const messages = [];

    // Send header text if present
    if (data.header) {
        messages.push({ type: 'text', text: { body: data.header } });
    }

    const cards = data.cards || [];
    for (const card of cards) {
        if (card.imageUrl) {
            const imageObj = { link: card.imageUrl };
            // Build caption from title + description
            let caption = '';
            if (card.title) caption += `*${card.title}*\n`;
            if (card.description) caption += card.description;
            if (caption) imageObj.caption = caption.trim();

            messages.push({ type: 'image', image: imageObj });
        } else {
            // No image — send as formatted text
            let text = '';
            if (card.title) text += `*${card.title}*\n`;
            if (card.description) text += card.description;
            messages.push({ type: 'text', text: { body: text.trim() || 'Card' } });
        }
    }

    return messages;
}

// Builds a WhatsApp Flow message (triggers a pre-created Flow by ID)
function buildFlowMessage(data) {
    const parameters = {
        flow_message_version: '3',
        flow_token: `flow-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`,
        flow_id: data.flowId,
        flow_cta: truncate(data.flowCta || 'Open', 20),
        flow_action: data.flowAction || 'navigate',
    };

    if (data.screenName) {
        parameters.flow_action_payload = {
            screen: data.screenName,
        };
        if (data.prefillData && typeof data.prefillData === 'object') {
            parameters.flow_action_payload.data = data.prefillData;
        }
    }

    const interactive = {
        type: 'flow',
        body: { text: data.body || '' },
        action: {
            name: 'flow',
            parameters,
        },
    };

    if (data.header) {
        interactive.header = { type: 'text', text: data.header };
    }
    if (data.footer) {
        interactive.footer = { text: data.footer };
    }

    return { type: 'interactive', interactive };
}

// ─── SEND TO WHATSAPP ────────────────────────────────────────────────────────
// Posts a formatted message to Meta's Send Message API.
async function sendToWhatsApp(phoneNumber, messageContent) {
    const url = `https://graph.facebook.com/v18.0/${CONFIG.metaPhoneNumberId}/messages`;

    const body = {
        messaging_product: 'whatsapp',
        to: phoneNumber,
        ...messageContent,
    };

    const response = await fetch(url, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${CONFIG.metaAccessToken}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
    });

    if (!response.ok) {
        const errorText = await response.text();
        console.error(`[Meta API] Send failed (${response.status}): ${errorText}`);
    } else {
        console.log(`[Meta API] Message sent to ${phoneNumber}`);
    }
}

// ─── UTILITY ─────────────────────────────────────────────────────────────────

// Truncates a string to a max length (Meta has strict limits on button/list text)
function truncate(str, maxLength) {
    if (!str) return '';
    if (str.length <= maxLength) return str;
    return str.substring(0, maxLength - 1) + '…';
}

// Clean up expired sessions every 10 minutes to prevent memory leaks
setInterval(() => {
    const now = Date.now();
    let cleaned = 0;
    for (const [phone, session] of sessions) {
        if (now - session.lastActivity > SESSION_TTL_MS) {
            sessions.delete(phone);
            cleaned++;
        }
    }
    if (cleaned > 0) {
        console.log(`[Cleanup] Removed ${cleaned} expired session(s)`);
    }
}, 10 * 60 * 1000);

// ─── START SERVER ────────────────────────────────────────────────────────────
app.listen(PORT, () => {
    console.log(`[Server] {ClientName} WhatsApp webhook running on port ${PORT}`);
    console.log(`[Server] Webhook URL: http://localhost:${PORT}/webhook`);

    // Validate that required env vars are set
    const required = ['META_VERIFY_TOKEN', 'META_ACCESS_TOKEN', 'META_PHONE_NUMBER_ID',
                      'SF_CLIENT_ID', 'SF_CLIENT_SECRET', 'SF_AGENT_ID'];
    const missing = required.filter(key => !process.env[key]);
    if (missing.length > 0) {
        console.warn(`[Warning] Missing environment variables: ${missing.join(', ')}`);
        console.warn('[Warning] The webhook will start but will fail to process messages.');
    }
});
