/**
 * Instagram Webhook Handler for {ClientName}
 *
 * A Node.js Express app that bridges Meta's Instagram Messaging API to
 * the Salesforce Agentforce Agent API. Receives Instagram DMs,
 * routes them to your agent, and sends rich responses back.
 *
 * Deployable to: Heroku, Railway, Vercel, or any Node.js host.
 *
 * Environment variables required (see .env.example):
 *   META_VERIFY_TOKEN, META_PAGE_ACCESS_TOKEN, META_INSTAGRAM_ID,
 *   SF_LOGIN_URL, SF_CLIENT_ID, SF_CLIENT_SECRET, SF_AGENT_ID
 */

const express = require('express');
const crypto = require('crypto');
const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json({ verify: (req, res, buf) => { req.rawBody = buf; } }));

const CONFIG = {
    metaVerifyToken: process.env.META_VERIFY_TOKEN,
    metaPageAccessToken: process.env.META_PAGE_ACCESS_TOKEN,
    metaAppSecret: process.env.META_APP_SECRET,
    metaInstagramId: process.env.META_INSTAGRAM_ID,
    sfLoginUrl: process.env.SF_LOGIN_URL || 'https://login.salesforce.com',
    sfClientId: process.env.SF_CLIENT_ID,
    sfClientSecret: process.env.SF_CLIENT_SECRET,
    sfAgentId: process.env.SF_AGENT_ID,
    surfaceId: '{surfaceId}',
};

// In-memory session store. Maps Instagram ASID → session data.
const sessions = new Map();
const SESSION_TTL_MS = 30 * 60 * 1000;

let sfAccessToken = null;
let sfInstanceUrl = null;
let sfTokenExpiry = 0;

app.get('/', (req, res) => {
    res.json({ status: 'ok', service: '{ClientName} Instagram Webhook' });
});

// GET /webhook — Meta verification challenge
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

// POST /webhook — Incoming Instagram messages
app.post('/webhook', async (req, res) => {
    // Verify signature if app secret is configured
    if (CONFIG.metaAppSecret && req.rawBody) {
        const signature = req.headers['x-hub-signature-256'];
        if (!verifySignature(req.rawBody, signature)) {
            console.warn('[Webhook] Invalid signature — rejecting');
            return res.status(401).send('Invalid signature');
        }
    }

    res.status(200).send('OK');

    try {
        const messageData = extractMessage(req.body);
        if (!messageData) return;

        const { senderId, text } = messageData;
        console.log(`[Message] From: ${senderId}, Text: "${text}"`);

        const session = await getOrCreateSession(senderId);
        const agentResponse = await callAgentAPI(session, text);
        const instagramMessages = translateToInstagram(agentResponse);

        for (const msg of instagramMessages) {
            await sendToInstagram(senderId, msg);
        }

        session.lastActivity = Date.now();

    } catch (error) {
        console.error('[Error] Processing message:', error.message);
        const senderId = extractSenderId(req.body);
        if (senderId) {
            await sendToInstagram(senderId, {
                text: "I'm having trouble right now. Please try again."
            });
        }
    }
});

function verifySignature(rawBody, signature) {
    if (!signature) return false;
    const expected = 'sha256=' + crypto
        .createHmac('sha256', CONFIG.metaAppSecret)
        .update(rawBody)
        .digest('hex');
    return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
}

// Instagram webhook payload structure differs from WhatsApp.
// Instagram uses: entry[].messaging[].message.text or .postback
function extractMessage(payload) {
    try {
        const entry = payload?.entry?.[0];
        const messaging = entry?.messaging?.[0];
        if (!messaging) return null;

        const senderId = messaging.sender?.id;
        if (!senderId) return null;

        // Skip echo messages (messages sent by the page itself)
        if (messaging.message?.is_echo) return null;

        let text = '';

        if (messaging.message?.text) {
            text = messaging.message.text;
        } else if (messaging.message?.quick_reply?.payload) {
            text = messaging.message.quick_reply.payload;
        } else if (messaging.postback?.payload) {
            text = messaging.postback.payload;
        } else {
            // Unsupported message type (attachment, story reply, etc.)
            console.log(`[Message] Unsupported message type from ${senderId}`);
            return null;
        }

        if (!text) return null;
        return { senderId, text };
    } catch (error) {
        console.error('[Error] Extracting message:', error.message);
        return null;
    }
}

function extractSenderId(payload) {
    try {
        return payload?.entry?.[0]?.messaging?.[0]?.sender?.id || null;
    } catch {
        return null;
    }
}

async function getOrCreateSession(senderId) {
    const existing = sessions.get(senderId);
    if (existing && (Date.now() - existing.lastActivity) < SESSION_TTL_MS) {
        return existing;
    }

    console.log(`[Session] Creating new session for ${senderId}`);
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
                externalSessionKey: `ig-${senderId}-${Date.now()}`,
                instanceConfig: { endpoint: sfInstanceUrl },
                streamingCapabilities: { chunkTypes: ['Text'] },
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

    sessions.set(senderId, session);
    return session;
}

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

// Translates Agent API structured responses to Instagram Send API format.
// Instagram uses the same Send API as Messenger with these template types:
//   - Quick Replies: message.quick_replies[]
//   - Generic Template: message.attachment.payload.template_type = "generic"
//   - Button Template: message.attachment.payload.template_type = "button"
//   - Media Template: message.attachment.payload.template_type = "media_template"
function translateToInstagram(agentResponse) {
    const messages = [];
    const agentMessages = agentResponse?.messages || [];

    for (const msg of agentMessages) {
        if (msg.type === 'Text') {
            const structured = tryParseStructured(msg.text);
            if (structured) {
                messages.push(...translateStructuredResponse(structured));
            } else {
                messages.push({ text: msg.text });
            }
        } else if (msg.type === 'RichContent' && msg.content) {
            messages.push(...translateStructuredResponse(msg.content));
        }
    }

    if (messages.length === 0) {
        messages.push({ text: 'I processed your request but have nothing to display.' });
    }

    return messages;
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

function translateStructuredResponse(structured) {
    const responseType = structured.type || structured.responseFormatType;

    switch (responseType) {
        case 'InstagramQuickReply':
            return [buildQuickReplyMessage(structured)];
        case 'InstagramGenericTemplate':
            return [buildGenericTemplate(structured)];
        case 'InstagramButtonTemplate':
            return [buildButtonTemplate(structured)];
        case 'InstagramMediaTemplate':
            return [buildMediaTemplate(structured)];
        default:
            const bodyText = structured.text || structured.body || JSON.stringify(structured);
            return [{ text: bodyText }];
    }
}

// Quick Reply: text message with tappable button pills
function buildQuickReplyMessage(data) {
    const quickReplies = (data.buttons || []).slice(0, 13).map(btn => ({
        content_type: 'text',
        title: truncate(btn.title, 20),
        payload: btn.payload || btn.title,
    }));

    return {
        text: data.text || '',
        quick_replies: quickReplies,
    };
}

// Generic Template: horizontal scrollable carousel cards
function buildGenericTemplate(data) {
    const elements = (data.elements || []).slice(0, 10).map(el => {
        const element = { title: truncate(el.title, 80) };

        if (el.subtitle) element.subtitle = truncate(el.subtitle, 80);
        if (el.image_url) element.image_url = el.image_url;

        if (el.buttons && el.buttons.length > 0) {
            element.buttons = el.buttons.slice(0, 3).map(btn => {
                const button = { type: btn.type, title: truncate(btn.title, 20) };
                if (btn.type === 'web_url') button.url = btn.url;
                if (btn.type === 'postback') button.payload = btn.payload;
                return button;
            });
        }

        return element;
    });

    return {
        attachment: {
            type: 'template',
            payload: {
                template_type: 'generic',
                elements,
            },
        },
    };
}

// Button Template: text with up to 3 structured buttons
function buildButtonTemplate(data) {
    const buttons = (data.buttons || []).slice(0, 3).map(btn => {
        const button = { type: btn.type, title: truncate(btn.title, 20) };
        if (btn.type === 'web_url') button.url = btn.url;
        if (btn.type === 'postback') button.payload = btn.payload;
        return button;
    });

    return {
        attachment: {
            type: 'template',
            payload: {
                template_type: 'button',
                text: truncate(data.text || '', 640),
                buttons,
            },
        },
    };
}

// Media Template: image or video with optional button
function buildMediaTemplate(data) {
    const payload = {
        template_type: 'media_template',
        elements: [{
            media_type: data.media_type || 'image',
            url: data.url,
        }],
    };

    if (data.buttons && data.buttons.length > 0) {
        const btn = data.buttons[0];
        const button = { type: btn.type, title: truncate(btn.title, 20) };
        if (btn.type === 'web_url') button.url = btn.url;
        if (btn.type === 'postback') button.payload = btn.payload;
        payload.elements[0].buttons = [button];
    }

    return {
        attachment: {
            type: 'template',
            payload,
        },
    };
}

// Send message to Instagram via the Send API
async function sendToInstagram(recipientId, messageContent) {
    const url = `https://graph.facebook.com/v21.0/${CONFIG.metaInstagramId}/messages`;

    const body = {
        recipient: { id: recipientId },
        message: messageContent,
    };

    const response = await fetch(url, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${CONFIG.metaPageAccessToken}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
    });

    if (!response.ok) {
        const errorText = await response.text();
        console.error(`[Meta API] Send failed (${response.status}): ${errorText}`);
    } else {
        console.log(`[Meta API] Message sent to ${recipientId}`);
    }
}

function truncate(str, maxLength) {
    if (!str) return '';
    if (str.length <= maxLength) return str;
    return str.substring(0, maxLength - 1) + '…';
}

// Clean up expired sessions every 10 minutes
setInterval(() => {
    const now = Date.now();
    let cleaned = 0;
    for (const [id, session] of sessions) {
        if (now - session.lastActivity > SESSION_TTL_MS) {
            sessions.delete(id);
            cleaned++;
        }
    }
    if (cleaned > 0) {
        console.log(`[Cleanup] Removed ${cleaned} expired session(s)`);
    }
}, 10 * 60 * 1000);

app.listen(PORT, () => {
    console.log(`[Server] {ClientName} Instagram webhook running on port ${PORT}`);
    console.log(`[Server] Webhook URL: http://localhost:${PORT}/webhook`);

    const required = ['META_VERIFY_TOKEN', 'META_PAGE_ACCESS_TOKEN', 'META_INSTAGRAM_ID',
                      'SF_CLIENT_ID', 'SF_CLIENT_SECRET', 'SF_AGENT_ID'];
    const missing = required.filter(key => !process.env[key]);
    if (missing.length > 0) {
        console.warn(`[Warning] Missing environment variables: ${missing.join(', ')}`);
        console.warn('[Warning] The webhook will start but will fail to process messages.');
    }
});
