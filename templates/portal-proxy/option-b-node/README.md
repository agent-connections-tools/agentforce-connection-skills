# {ClientName} Portal — Node.js + React

An in-app chat interface powered by Agentforce, with rich interactive response formats (cards, lists, buttons, forms, carousels).

## Architecture

```
Browser (React)  →  /api/agent  →  Express Proxy  →  Agent API (Salesforce)
                                   (holds secrets,
                                    validates user JWT,
                                    manages sessions)
```

The browser never talks to Salesforce directly. All auth and session management lives in the proxy.

## Prerequisites

- Node.js 18+
- A deployed Custom Connection (run `deploy.sh` from the parent directory first)
- Salesforce ECA credentials (Setup > External Client Apps)
- An IdP configured (Auth0, Okta, or Salesforce Identity)

## Local Development

1. **Install dependencies:**

   ```bash
   cd server && npm install && cd ..
   cd client && npm install && cd ..
   ```

2. **Configure the server:**

   ```bash
   cp server/.env.example server/.env
   # Edit server/.env with your credentials
   ```

   For local dev, you can set `ALLOW_ANONYMOUS=true` to skip auth while testing.

3. **Start both server and client:**

   ```bash
   # Terminal 1: start the proxy
   cd server && npm run dev

   # Terminal 2: start the React client
   cd client && npm run dev
   ```

4. **Open http://localhost:5173** — the Vite dev server proxies `/api` requests to the Express server.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SF_LOGIN_URL` | Yes | Your Salesforce org URL (e.g., `https://yourorg.my.salesforce.com`) |
| `SF_CLIENT_ID` | Yes | ECA consumer key |
| `SF_CLIENT_SECRET` | Yes | ECA consumer secret |
| `SF_AGENT_ID` | Yes | Agentforce agent ID (`0Xx...`) |
| `AUTH_JWKS_URI` | Yes* | JWKS endpoint for your IdP |
| `AUTH_ISSUER` | Yes* | Expected JWT issuer |
| `AUTH_AUDIENCE` | Yes* | Expected JWT audience |
| `PORT` | No | Server port (default: 3001) |
| `ALLOWED_ORIGIN` | No | CORS origin (default: `http://localhost:5173`) |
| `ALLOW_ANONYMOUS` | No | Set `true` for local dev only — disables auth |

*Not required if `ALLOW_ANONYMOUS=true` (local dev only).

## Supported Response Formats

| Format | Renders As |
|--------|-----------|
| InAppCard | Bordered card with title, body, image, action buttons |
| InAppList | Vertical list with icon, title, subtitle per row |
| InAppButtonGroup | 1-6 action buttons below a message |
| InAppForm | Input fields (text, email, number, select, checkbox) + submit |
| InAppCarousel | Horizontal scrollable cards with images and buttons |

The agent selects the appropriate format automatically based on conversation context.

## Deploying to Production

```bash
./deploy_heroku.sh your-app-name
```

Or deploy to any Node.js host (Railway, AWS, Render):
1. Build the client: `cd client && npm run build`
2. Copy `client/dist/` to `server/public/`
3. Deploy the `server/` directory
4. Set all environment variables
5. Ensure `ALLOW_ANONYMOUS` is NOT set (defaults to auth-required)

## Security

- ECA secrets are server-side only — never exposed to the browser
- End-user JWT is validated on every request (JWKS with key rotation support)
- CSP should block `*.salesforce.com` from browser origins
- `ALLOW_ANONYMOUS=true` is for local dev only — in production, auth is always required
- Tokens are never logged

## API Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/agent/message` | JWT required | Send message, get structured response |
| POST | `/api/agent/session/reset` | JWT required | End conversation, start fresh |
| GET | `/api/health` | None | Health check |
