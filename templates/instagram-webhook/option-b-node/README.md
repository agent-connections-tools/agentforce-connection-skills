# {ClientName} Instagram Webhook

Bridges Meta's Instagram Messaging API to Salesforce Agentforce Agent API.

## Setup

1. **Meta App Dashboard** — Create an app at developers.facebook.com with Instagram Messaging product enabled
2. **Instagram Professional Account** — Connect your Instagram Business/Creator account to the Meta app
3. **Generate Page Access Token** — With `instagram_manage_messages` and `pages_messaging` permissions
4. **Salesforce ECA** — Create an External Client App with `api`, `chatbot_api`, `sfap_api` scopes and client_credentials enabled
5. **Deploy** — Run `./deploy_heroku.sh` or deploy manually to Railway/Vercel
6. **Configure Webhook** — In Meta App Dashboard > Instagram > Webhooks, set your callback URL and verify token
7. **Subscribe** — Subscribe to `messages` and `messaging_postbacks` webhook fields

## Environment Variables

| Variable | Description |
|----------|-------------|
| `META_VERIFY_TOKEN` | Random string matching Meta's webhook config |
| `META_PAGE_ACCESS_TOKEN` | Token with instagram_manage_messages permission |
| `META_APP_SECRET` | For webhook signature verification |
| `META_INSTAGRAM_ID` | Your Instagram Professional Account ID |
| `SF_LOGIN_URL` | `https://login.salesforce.com` or `https://test.salesforce.com` |
| `SF_CLIENT_ID` | ECA consumer key |
| `SF_CLIENT_SECRET` | ECA consumer secret |
| `SF_AGENT_ID` | Agentforce agent BotDefinition ID |

## Testing

Send a DM to your Instagram Professional Account. The agent should respond with rich formats (carousels, buttons, quick replies) based on the conversation context.
