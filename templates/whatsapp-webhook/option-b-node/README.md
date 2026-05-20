# WhatsApp Webhook for {ClientName} (Node.js — deploy anywhere)

This webhook handler connects Meta's WhatsApp Cloud API to your Agentforce agent. When someone sends a WhatsApp message to your business number, this app receives it, sends it to your agent, and replies with the agent's response — including rich messages like buttons, lists, and images.

Runs on: Heroku, Railway, Vercel, or any platform that hosts Node.js apps.

---

## Prerequisites

Before you start, make sure you have:

- [ ] **Node.js 18+** installed on your computer ([download here](https://nodejs.org))
- [ ] A **Heroku** or **Railway** account for hosting
- [ ] A **Meta Business Account** (business.facebook.com)
- [ ] **WhatsApp Business API** access (applied through Meta Business Suite)
- [ ] A phone number registered with WhatsApp Business
- [ ] A Salesforce org with **Agentforce** enabled
- [ ] An agent already configured with a Custom Connection surface
- [ ] An External Client App (ECA) set up in Salesforce (Client Credentials flow)

---

## Step 1: Create a Meta App

1. Go to [developers.facebook.com](https://developers.facebook.com) and click **Create App**
2. Select **Business** as the app type
3. Fill in a name (e.g., "{ClientName} WhatsApp Bot") and select your Business Account
4. Once created, find **WhatsApp** in the product list and click **Set Up**
5. You'll see:
   - **Temporary Access Token** — copy it (you'll need it in Step 3)
   - **Phone Number ID** — copy this too
6. Make up a **Verify Token** — any random string you want (e.g., `my-secret-token-2024`). You'll use this in both Step 3 and Step 4.

> **Important:** The temporary access token expires in 24 hours. For production, create a permanent System User token: Meta Business Suite > Settings > Business Settings > System Users > Generate Token.

<!-- Screenshot: Meta App Dashboard showing WhatsApp Getting Started page -->

---

## Step 2: Get Your Salesforce Credentials

You need an External Client App (ECA) for this webhook to authenticate with Salesforce.

1. In Salesforce Setup, search for **App Manager**
2. Click **New Connected App** > **Create an External Client App**
3. Configure:
   - **Name:** `{ClientName} WhatsApp Webhook`
   - **OAuth flow:** Client Credentials
   - **Scopes:** `api`, `einstein_gpt_api`
4. Save and note your **Consumer Key** and **Consumer Secret**
5. Also note your **Agent ID** — find it in Setup > Agents > click your agent > the ID is in the URL

---

## Step 3: Deploy

### Option A: Deploy to Heroku (one command)

1. Copy `.env.example` to `.env` and fill in your values:
   ```bash
   cp .env.example .env
   ```

2. Open `.env` in any text editor and fill in all the values from Steps 1 and 2

3. Run the deploy script:
   ```bash
   chmod +x deploy_heroku.sh
   ./deploy_heroku.sh
   ```

4. The script will print your webhook URL when done

### Option B: Deploy to Railway

1. Install Railway CLI: `npm install -g @railway/cli`
2. Login: `railway login`
3. Create project: `railway init`
4. Set each environment variable:
   ```bash
   railway variables set META_VERIFY_TOKEN=your-token
   railway variables set META_ACCESS_TOKEN=your-meta-token
   railway variables set META_PHONE_NUMBER_ID=your-number-id
   railway variables set SF_LOGIN_URL=https://login.salesforce.com
   railway variables set SF_CLIENT_ID=your-consumer-key
   railway variables set SF_CLIENT_SECRET=your-consumer-secret
   railway variables set SF_AGENT_ID=your-agent-id
   ```
5. Deploy: `railway up`
6. Get your URL: `railway domain`

### Option C: Run locally (for testing)

```bash
npm install
cp .env.example .env
# Fill in .env values
npm start
```

Use [ngrok](https://ngrok.com) to expose your local server:
```bash
ngrok http 3000
```

---

## Step 4: Configure Meta Webhook URL

1. Go back to your Meta App at [developers.facebook.com](https://developers.facebook.com)
2. Navigate to **WhatsApp** > **Configuration**
3. Under **Webhook**, click **Edit**
4. Enter:
   - **Callback URL:** Your deployed app URL + `/webhook`
     - Heroku: `https://whatsapp-webhook-{ClientName}.herokuapp.com/webhook`
     - Railway: `https://your-app.up.railway.app/webhook`
   - **Verify Token:** The same string you put in `META_VERIFY_TOKEN`
5. Click **Verify and Save** (Meta will send a GET request to confirm)
6. Under **Webhook Fields**, subscribe to **messages**

<!-- Screenshot: Meta webhook configuration page -->

---

## Step 5: Test

1. Open WhatsApp on your phone
2. Send a message to your WhatsApp Business number
3. Wait a few seconds — you should see a response from your agent
4. If your agent uses rich response formats, you'll see:
   - **Buttons** — tappable options below the message
   - **Lists** — expandable menu with sections
   - **Images/Videos** — media with captions
   - **Carousel** — multiple image cards in sequence

### Quick test checklist:
- [ ] Sent "Hello" — got a response
- [ ] Tapped a button — agent understood the selection
- [ ] Sent a question that triggers a list response — list appeared
- [ ] Waited 30+ minutes and sent again — new session started cleanly

---

## Troubleshooting

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| Meta says "Callback URL verification failed" | Verify token mismatch or app not running | Check META_VERIFY_TOKEN matches. Check app logs for errors |
| Messages sent but no response | Salesforce auth failing | Check SF_CLIENT_ID and SF_CLIENT_SECRET. Look at logs |
| "I'm having trouble right now" reply | Agent API call failed | Check logs (`heroku logs --tail`). Verify agent works in Agentforce console |
| 401 from Salesforce | Token expired or bad credentials | Double-check ECA credentials. Make sure scopes include `einstein_gpt_api` |
| 400 from Meta Send API | Message format issue | Check logs for the exact error. Common: button title too long (max 20 chars) |
| 403 from Meta Send API | Token expired | Generate a new permanent token via System User |
| Duplicate responses | Webhook called multiple times | Meta retries on slow responses. The app returns 200 immediately, so this is rare. Check for multiple webhook subscriptions |
| App crashes on start | Missing env vars | Check that all required environment variables are set |
| Sessions reset unexpectedly | App restarted (in-memory sessions lost) | Expected on free-tier Heroku. For production, add Redis (see below) |

---

## Monitoring

### View logs

**Heroku:**
```bash
heroku logs --tail --app whatsapp-webhook-{ClientName}
```

**Railway:**
```bash
railway logs
```

### What the logs show

- `[Message] From: 1234567890, Text: "Hello"` — incoming message received
- `[Session] Creating new session for 1234567890` — new conversation started
- `[Meta API] Message sent to 1234567890` — reply delivered
- `[Auth] Refreshing Salesforce access token` — token rotation (normal)
- `[Error] ...` — something went wrong (check the message)

---

## Production Recommendations

For a production deployment handling real customer traffic:

1. **Use Redis for sessions** — In-memory sessions are lost when the app restarts. Add Redis:
   ```bash
   heroku addons:create heroku-redis:mini
   ```
   Then swap the `sessions` Map for a Redis client.

2. **Use a permanent Meta token** — Create a System User in Meta Business Suite and generate a non-expiring token.

3. **Add rate limiting** — Meta has sending limits. Start with 1,000 messages/day and request increases.

4. **Monitor with alerts** — Set up log-based alerts for `[Error]` entries.

5. **Scale horizontally** — The app is stateless (if using Redis). Add more dynos/instances as needed.

---

## How It Works (Architecture)

```
WhatsApp User
     │
     ▼
Meta Cloud API ──POST──▶ Node.js Express App (/webhook)
                                  │
                        ┌─────────┴──────────┐
                        ▼                    ▼
                 Session Lookup        Salesforce OAuth
                (in-memory Map)      (Client Credentials)
                        │                    │
                        └─────────┬──────────┘
                                  ▼
                         Agent API Call
                    (POST /sessions/:id/messages)
                                  │
                                  ▼
                       translateToWhatsApp()
                    (convert response formats)
                                  │
                                  ▼
                       POST to Meta Send API
                     (graph.facebook.com/v18.0)
                                  │
                                  ▼
                         WhatsApp User sees
                           rich response
```
