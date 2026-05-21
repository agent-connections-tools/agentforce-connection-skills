# scaffold-portal-app — Skill Plan (v3)

**Author:** Abhi Rathna
**Date:** 2026-05-20
**Status:** Draft — awaiting design partner validation

---

## What This Skill Does

Given a client name and agent ID, the skill generates a deployable Custom Connection for in-app / portal use cases: the AiSurface metadata, five response format schemas, a server-side proxy (Apex or Node), and a reference frontend implementation.

The core deliverable is the **format layer + proxy** — framework-agnostic by design. The React starter is one reference implementation. LWC on Experience Cloud is a second. Angular, native iOS/Android, and other frameworks are documented as porting targets.

---

## Who It's For

**Primary persona:** Developers building customer-facing portals or internal tools that need an embedded AI agent with rich interactive responses.

**Secondary persona:** Solution engineers demoing Custom Connections to prospects with their own digital properties (banking apps, insurer portals, automaker apps, Experience Cloud sites).

---

## The Problems It Solves

1. **No reference implementation exists.** Developers read the Agent API docs but have no starting point for a browser-based integration with rich media.
2. **ECA secrets leak to the client.** Without a proxy layer, developers put client_credentials in the browser — a security incident waiting to happen.
3. **No format library for in-app surfaces.** WhatsApp and Teams have defined card schemas. Custom portals have nothing — every team reinvents the wheel.
4. **Session management is non-obvious.** Mapping a browser/app session to an Agent API session (create, reuse, expire) requires boilerplate that's easy to get wrong.
5. **End-user auth is unsolved.** The proxy authenticates to Salesforce, but who authenticates the portal user to the proxy? Every enterprise security team asks this first.

---

## Why This Is the Flagship Skill

- It's the only use case where Custom Connections is the **only** path (messaging channels have OOTB options now).
- Maps directly to the highest-value enterprise deals (banking, auto, insurance portals).
- Significant reuse of WhatsApp/Teams template scaffolding — breakdown by layer:

  | Layer | Reuse | Notes |
  |-------|-------|-------|
  | ECA auth (client_credentials, token cache, refresh) | ~100% | Identical pattern, copy and adapt |
  | Session management (user ID → Agent API session) | ~80% | Same map structure, different key (session cookie vs phone/conversation ID) |
  | AiSurface + deploy script wiring | ~100% | Identical XML skeleton + GenAiPlannerBundle pattern |
  | Response format schemas | ~20% | Same XML structure, entirely new field schemas |
  | Frontend renderers | 0% from existing skills | New — but ~50% reuse between LWC and React renderers (same JSON contracts, same state machine, different component syntax) |
  | End-user auth middleware | 0% | New — WhatsApp/Teams don't authenticate end users |
- Clean SKO/Dreamforce demo: "type a prompt, agent renders an interactive React form inline in the portal."
- LWC path gives Sales a "deploys in your existing Experience Cloud site" story with auth already solved.

---

## Deliverables

### 1. AiSurface Metadata + Response Format Schemas (the core)

This is the load-bearing piece — framework-agnostic, works with any frontend.

| File | Purpose |
|------|---------|
| `{ClientName}PortalSurface_{surfaceId}.aiSurface` | Registers the portal as a Custom Connection surface |
| `{ClientName}InAppCard_{surfaceId}.aiResponseFormat` | Card format schema |
| `{ClientName}InAppList_{surfaceId}.aiResponseFormat` | List format schema |
| `{ClientName}InAppButtonGroup_{surfaceId}.aiResponseFormat` | Button group format schema |
| `{ClientName}InAppForm_{surfaceId}.aiResponseFormat` | Form format schema |
| `{ClientName}InAppCarousel_{surfaceId}.aiResponseFormat` | Carousel format schema |

Plus surface instructions that tell the agent when to pick each format.

### 2. In-App Response Format Library

Five formats, each with a JSON Schema contract (registered as an AiResponseFormat):

| Format | What It Renders | Best For |
|--------|----------------|----------|
| InAppCard | Bordered card with title, body, image, action buttons | Single-item display (order status, article, product) |
| InAppList | Vertical list with icon, title, subtitle per row | Search results, recent items, recommendations |
| InAppButtonGroup | 1-6 labeled buttons below a message | Confirm/cancel, navigation, quick actions |
| InAppForm | Input fields + submit button (see scope below) | Data collection (lead capture, feedback, preferences) |
| InAppCarousel | Horizontal scrollable cards | Product comparisons, multi-item browse |

**InAppForm scope (v1):** text, email, number, select (single), checkbox. Each field supports a `required` flag and a `pattern` regex for basic validation. No date pickers, multi-select, file upload, or conditional fields in v1 — those are v2 once a design partner validates the base set.

Each format enforces field limits in the JSON Schema. The agent can't hallucinate extra fields because the schema rejects them.

### 3. Server-Side Proxy (Two Options)

Mirrors the Teams/WhatsApp two-option pattern:

| Option | Stack | Best For |
|--------|-------|----------|
| **Option A: Apex** | Apex REST class on the same org | Customers running Experience Cloud / LWR portals. No external infra needed. Auth inherits from Salesforce Identity. |
| **Option B: Node.js** | Express.js on customer infra (Heroku, Railway, AWS, etc.) | Customers running their own frontend stack (React, Angular, native). Requires separate end-user auth. |

Both options handle:

| Responsibility | How |
|----------------|-----|
| ECA secrets held server-side | Env vars (Node) or Named Credential (Apex) — never exposed to browser/app |
| Salesforce OAuth | client_credentials flow, token caching, auto-refresh |
| Session management | Maps end-user session → Agent API session ID |
| Response delivery | Returns structured JSON for the frontend to render |
| Error / timeout handling | Returns structured error responses (see UX section below) |

**Streaming:** The Node proxy supports SSE for progressive rendering IF the Agent API supports chunked streaming. See P1 blocker below — this must be verified before building. If not supported, the proxy uses request/response and success criterion #4 is deferred.

### 4. Reference Frontend Implementations

**v1 ships two:**

#### Option A: LWC on Experience Cloud

- Drops into an existing Experience Cloud site as a custom component
- Auth is solved (inherits Salesforce Identity session)
- Calls the Apex proxy via Continuation (async callout pattern) — required because agent responses typically take 5-15s, which would hit synchronous transaction CPU/heap limits and block initial render
- Ships with SLDS styling for visual consistency
- Easiest path for Salesforce-native customers

**Why Continuation, not @AuraEnabled with synchronous callout:** A synchronous Apex callout blocks the entire transaction. Agent API responses routinely take 5-15 seconds. During that wait, the transaction accumulates CPU time toward governor limits, the LWC component is frozen (no spinner, no cancel), and the component can't be used anywhere that requires fast initial render. Continuation solves all three: it releases the transaction, resumes only when the callout returns, and lets the LWC show a loading state while waiting. This is a v1 deliverable, not a "document if needed" — without it the LWC path works in demos (fast sandbox agents) and breaks in production (real agent reasoning times).

**Continuation constraints:** 120s callout timeout (sufficient for agent responses, but the component should still show a timeout UX after 60s). Continuations do not work inside `@AuraEnabled(cacheable=true)` methods — the proxy method must be non-cacheable.

#### Option B: React + Vite Starter

- Standalone app for customers running their own frontend
- TypeScript, minimal CSS (Tailwind optional, not required)
- Calls the Node proxy via `/api/agent`
- Ships with format renderer components for all 5 formats

**Documented porting targets (not shipped, but documented):**

| Framework | What We Document |
|-----------|-----------------|
| Angular | Component structure mapping, service pattern for proxy calls |
| React Native | Same format contracts, native renderer guidance |
| Native iOS (SwiftUI) | JSON parsing patterns, equivalent UI components |
| Native Android (Compose) | Same as iOS but Kotlin/Compose |

The documentation covers: (1) the JSON contract each format returns, (2) how to call the proxy, (3) how to handle streaming vs request/response, (4) how to render each format type. Framework-specific code is out of scope for v1 — the contracts are the interface.

### 5. End-User Auth (P0 Design Decision)

**Stance:** The proxy validates end-user identity via OIDC. We ship reference middleware for three IdPs:

| IdP | Why |
|-----|-----|
| Salesforce Identity | Covers Experience Cloud users and internal portals. Zero-config for Option A (Apex). |
| Auth0 | Most common in custom React/Angular portals among enterprise customers. |
| Okta | Second most common. Similar OIDC flow to Auth0. |

**How it works:**

1. Portal user authenticates with their IdP (standard OIDC redirect or embedded login)
2. Portal sends the resulting JWT/session token with every proxy request
3. Proxy validates the token against the IdP's JWKS endpoint
4. On success, proxy maps the authenticated user to an Agent API session
5. Optionally maps the user identity to a Salesforce Contact (for personalized agent responses — `bypassUser: false`)

**Option A (Apex/LWC) gets this for free** — the user is already authenticated via Salesforce Identity. No extra middleware needed. This is a major advantage of the LWC path and why it may be the better v1 default for risk-averse enterprise customers.

**Option B (Node) requires explicit configuration.** The skill generates the middleware slot with Auth0 as the default reference implementation. Swap for Okta/custom by changing the JWKS URL and issuer.

### 6. Accessibility + CSP

**Accessibility (WCAG 2.1 AA):**
- All format renderer components ship with keyboard navigation and appropriate ARIA labels
- Focus management when new messages / cards appear
- Color contrast meets AA ratios in default theme
- Screen reader announces new agent responses

**Content Security Policy:**
- Starter app documents required CSP rules
- Mandates that `*.salesforce.com` is NOT in the browser's allowed origins (enforces "browser never talks to Salesforce directly" at the CSP level, not just by convention)
- Documents required CSP entries for the IdP (Auth0/Okta/SF Identity JWKS endpoints)
- **Note:** The CSP `*.salesforce.com` block applies to non-Salesforce-hosted frontends only (React, Angular, native). Experience Cloud LWC components live on `*.force.com` / `*.salesforce-experience.com` and talk to Apex same-origin — no CSP conflict. The LWC path doesn't need this rule.

### 7. Error / Fallback UX

Every reference frontend ships with these states:

| State | What User Sees |
|-------|---------------|
| Proxy unreachable | "Unable to connect. Retrying..." with exponential backoff |
| Agent timeout (>30s) | "Taking longer than expected. Still working..." then fallback to text-only after 60s |
| Unknown format returned | Renders as plain text with a subtle "unsupported format" indicator in dev mode |
| Session expired | Transparent re-creation — user sees brief "Reconnecting..." then continues |
| Rate limited | "Too many requests. Please wait a moment." |

### 8. Deploy Script

A single shell script (`deploy_portal_connection.sh`) that the admin runs after generation:

```bash
./deploy_portal_connection.sh --target-org my-sandbox --agent-id 0XxXXXXXXXXXXXX
```

**What it does, in order:**

1. **Validates** — runs `sf project deploy start --dry-run` against the target org to catch metadata errors before writing anything
2. **Deploys AiSurface + AiResponseFormats** — pushes the 6 metadata files (1 surface + 5 formats) via Metadata API
3. **Wires to agent** — updates (or creates) the GenAiPlannerBundle to associate the new surface and formats with the specified agent ID
4. **Verifies** — queries the org to confirm the surface is active and all 5 formats are registered
5. **Reports** — prints a summary: what was deployed, the surface ID, and a link to the agent in Setup

**What the admin gets:** A fully wired Custom Connection — the agent immediately starts using the in-app formats on the next session created with `surfaceType: "Custom"`. No manual Setup clicks required.

**Prerequisites:** `sf` CLI authenticated to the target org (`sf org login` already done).

---

## What the Skill Asks (Questions)

| # | Question | Used For |
|---|----------|----------|
| Q1 | Client name | File naming, metadata API names |
| Q2 | Use case (user picks "In-app portal / custom UI") | Selects this skill path |
| Q3 | Agent ID | Wiring the connection to the agent |
| Q4 | Include MIAW handoff? | Adds human escalation config |
| Q5 | Generate the reference app + proxy? | If yes: which option? |
| Q5a | (If yes) Apex + LWC, Node + React, or both? | Determines which reference implementation(s) to generate |
| Q6 | (If Node selected) Streaming or request/response? | Determines proxy architecture (SSE vs polling) — only asked if streaming is confirmed supported |

**Q5a "Both" option:** Generates both implementations side-by-side in separate directories (`portal-lwc/` and `portal-react/`). Both share the same AiSurface metadata and response format schemas — the deploy script wires one Custom Connection that works with either proxy. Use case: customer has Experience Cloud for retail customers AND a custom React app for B2B partners, both talking to the same agent. "Both" still fits within the 10-13 day total because the metadata, auth middleware, and deploy script are shared — the incremental cost is the second set of frontend renderers (~2 days, offset by cross-implementation reuse).

---

## Architecture

```
┌─────────────────┐        ┌─────────────────┐        ┌─────────────────┐
│  Frontend        │  HTTPS │  Proxy           │  HTTPS │  Agent API       │
│  (LWC or React)  │◄──────►│  (Apex or Node)  │◄──────►│  (Salesforce)    │
│                  │        │                  │        │                  │
│  - Chat surface  │        │  - End-user auth │        │  - Session mgmt  │
│  - Format render │        │  - ECA auth      │        │  - Reasoning     │
│  - Error states  │        │  - Session map   │        │  - CRM data      │
│                  │        │  - Token cache   │        │  - Trust layer   │
└─────────────────┘        └─────────────────┘        └─────────────────┘
         │                                                       
         │  CSP blocks *.salesforce.com                          
         │  (browser NEVER talks to SF directly)                 
```

---

## Reuse from Existing Skills

| Existing Asset | Reused How |
|----------------|-----------|
| ECA auth pattern (WhatsApp/Teams handlers) | Same client_credentials flow, token caching, refresh logic |
| Session management (ID → session map) | Same pattern, keyed by authenticated user ID |
| AiResponseFormat XML template structure | Same XML skeleton, different field schemas |
| AiSurface + GenAiPlannerBundle wiring | Identical deploy script pattern |
| Surface instructions (when to pick each format) | Same structure, rewritten for in-app context |
| Two-option proxy pattern (Apex / Node) | Same structural split, same README pattern |

---

## Blockers (must resolve before building)

| # | Blocker | Impact | Resolution Path |
|---|---------|--------|-----------------|
| P1 | Does Agent API support chunked/streaming responses today? | If no: SSE streaming is unbuildable, success criterion #4 deferred, Node proxy falls back to request/response only | Test against sandbox with streaming config. If unsupported, document as future enhancement and ship request/response. |
| P2 | Resolved (Continuations required, v1 deliverable). | Synchronous Apex callouts block the transaction for 5-15s (agent response time), hitting CPU/heap limits and freezing the component. | Apex proxy uses Continuation pattern (async callout). See Option A details above. |

---

## Open Questions (v2 — deprioritized)

| # | Question | Disposition |
|---|----------|-------------|
| 1 | React Native reference implementation? | Defer to v2. Document porting patterns in v1. |
| 2 | InAppForm date picker / file upload / conditional fields? | v2. Start with text/email/number/select/checkbox in v1. |
| 3 | Multi-agent routing (one portal, multiple agents)? | v2. Single-agent in v1. |
| 4 | Proactive messages (agent-initiated, not user-initiated)? | v2. Requires WebSocket or push infra. |

---

## Design Partner Criteria

Ideal design partner:

- Has an existing customer-facing portal or Experience Cloud site (not greenfield)
- Already using Agentforce (or actively evaluating)
- Wants to embed agent interactions inside their own UI
- Willing to deploy to a sandbox and give feedback over 2 weeks
- **Bonus:** Already on Experience Cloud (fastest path to production — auth is solved)

Target verticals: Financial services, insurance, automotive, healthcare.

**Why LWC/Experience Cloud customers are the best first partners:** Auth is solved, deployment is familiar, and we can validate the format library without getting blocked on end-user auth debates. The Node/React path is validated second with a partner who has custom infra.

**Realistic feedback timeline:** First round of feedback (formats work, basic flow validated) in 2 weeks. Full validation pass (auth edge cases, production-readiness, accessibility, real user testing) over 4-6 weeks. Design partners writing their own portal code on top of the starter need the longer timeline.

---

## Success Criteria

1. Developer using the LWC path drops the component into an Experience Cloud site, deploys metadata, and has a working agent chat with rich responses in under 15 minutes.
2. Developer using the React path clones the starter, sets env vars, runs `npm run dev`, and has a working chat in under 15 minutes.
3. Agent correctly selects and populates all 5 format types based on conversation context.
4. No secrets are ever exposed to the browser — enforced by CSP blocking `*.salesforce.com` from the browser origin, not just by convention.
5. Streaming responses render progressively (Node path only, contingent on P1 blocker resolution).
6. End-user identity is validated on every proxy request — no anonymous access to the agent unless `ALLOW_ANONYMOUS=true` is explicitly set in env vars. The Node proxy defaults to auth-required; the flag exists only for local development. The LWC path has no anonymous mode — an authenticated Salesforce Identity user is always required. For guest-user / unauthenticated Experience Cloud sites, the LWC component must be configured to run under a guest-user license with appropriate object permissions; this is documented as a separate setup path.
7. All format renderer components pass WCAG 2.1 AA automated checks (keyboard nav, ARIA labels, color contrast).
8. Deploy script wires the Custom Connection to the agent in one command.
9. Error/fallback states render correctly when proxy is down, agent times out, or unknown format is returned.

---

## Timeline Estimate

| Phase | Duration | Output |
|-------|----------|--------|
| Format schemas + AiSurface metadata | 1-2 days | 5 response formats + surface definition, deployable |
| Apex proxy + LWC reference frontend | 2-3 days | Working LWC component + Apex proxy with auth |
| Node proxy + React reference frontend | 3-4 days | Working React app + Express proxy + auth middleware |
| End-user auth middleware (Auth0 + Okta reference) | 2-3 days | OIDC validation middleware with JWKS, error handling, tested for both IdPs |
| Accessibility pass + CSP documentation | 1 day | WCAG compliance, CSP rules documented |
| Skill integration (questions, generation logic) | 1 day | Wired into build-custom-connection flow |
| Porting documentation (Angular, native) | 1 day | How-to docs for non-shipped frameworks |
| **Total engineering** | **10-13 days** | |
| Design partner validation (parallel) | 4-6 weeks | First feedback at week 2; full validation (auth, a11y, production edge cases) by week 4-6 |

---

## v2 Roadmap (post-design-partner)

- React Native reference implementation
- InAppForm: date picker, multi-select, file upload, conditional fields
- Multi-agent routing
- Proactive messages (agent-initiated push)
- Angular reference implementation (if design partner demand)
- Native iOS/Android reference implementation (if design partner demand)
