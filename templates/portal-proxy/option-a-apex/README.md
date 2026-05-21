# {ClientName} Portal — Apex + LWC (Experience Cloud)

An in-app chat component for Experience Cloud powered by Agentforce, with rich interactive response formats (cards, lists, buttons, forms, carousels).

## Architecture

```
Experience Cloud Page  →  LWC Component  →  Apex Proxy (Continuation)  →  Agent API
                          (renders formats)   (holds Named Credential,
                                               manages sessions via
                                               Platform Cache)
```

Auth inherits from Salesforce Identity — the user is already authenticated via their Experience Cloud session. No separate auth middleware needed.

## Prerequisites

- A deployed Custom Connection (run `deploy.sh` from the parent directory first)
- Named Credential configured for Agent API
- Platform Cache partition with at least 1MB allocated
- Experience Cloud site (the LWC component targets `lightningCommunity__Page`)

## Deployment

```bash
./deploy_portal.sh my-sandbox
```

## Setup

### 1. Named Credential

Setup > Named Credentials > New:

| Field | Value |
|-------|-------|
| Label | `AgentAPI_{ClientName}` |
| URL | `https://yourorg.my.salesforce.com` |
| Identity Type | Named Principal |
| Authentication Protocol | OAuth 2.0 |
| Auth Provider | Create one using your ECA consumer key + secret |
| Scope | `api chatbot_api sfap_api` |

### 2. Platform Cache

Setup > Platform Cache:
- Create or select an org partition
- Allocate at least 1MB to the org cache
- Sessions are stored here (30 min TTL)

### 3. Add to Experience Cloud

1. Open Experience Builder for your site
2. Drag the "{Client Display Name} Chat" component onto any page
3. Publish the site

## How It Works

1. User opens the Experience Cloud page — LWC calls `startCreateSession` (Continuation)
2. Apex creates an Agent API session and caches it in Platform Cache (30 min TTL)
3. User types a message — LWC calls `startSendMessage` (Continuation, 120s timeout)
4. Apex sends the message to Agent API, parses the structured response
5. LWC renders the response using the format renderer (Card, List, ButtonGroup, Form, Carousel)
6. User interacts with buttons/forms — LWC sends the action back as a new message

## Why Continuation (not synchronous callout)

Agent API responses take 5-15 seconds. A synchronous `@AuraEnabled` callout would:
- Block the transaction and accumulate CPU time toward governor limits
- Freeze the LWC component (no loading spinner, no cancel)
- Prevent use on pages that need fast initial render

Continuation releases the transaction immediately. The LWC shows a loading state while waiting. When the callout returns, Apex resumes and sends the response back.

**Constraints:**
- 120s callout timeout (sufficient for agent responses)
- Continuation methods must NOT be `cacheable=true`
- Platform Cache is required for session persistence across requests

## Supported Response Formats

| Format | Renders As |
|--------|-----------|
| InAppCard | SLDS card with title, body, image, action buttons |
| InAppList | Vertical list with icon, title, subtitle per row |
| InAppButtonGroup | lightning-button group below a message |
| InAppForm | lightning-input fields + lightning-combobox + submit |
| InAppCarousel | Horizontal scrollable cards with images and buttons |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| "Cache not available" | Allocate Platform Cache (Setup > Platform Cache) |
| "Unauthorized" callout error | Check Named Credential — ensure OAuth is configured with correct ECA credentials |
| Continuation timeout (>120s) | Agent is taking too long — simplify the topic or check for loops in agent config |
| Component not visible in Experience Builder | Check `.js-meta.xml` targets include `lightningCommunity__Page` |
| Session expires mid-conversation | Expected — component automatically reconnects with "Reconnecting..." message |
