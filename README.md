# Custom Connections Skills for Agentforce

Four Claude Code skills that take the pain out of working with Custom Connections in Agentforce — one to **build** them, one to **diagnose** them when something's wrong, one to **update** them after the first deploy, and one to **test** them end-to-end. The build skill also supports optional **human handoff via MIAW** (Messaging for In-App and Web) — so your agent can transfer conversations to a live person when it can't resolve an issue.

## The four skills

| Skill | What it does | When to use |
|------|------|------|
| **`/project:build-custom-connection`** | Generates all the metadata for a new custom connection. Answer 4 questions, get a deploy-ready package. Optionally adds human handoff via MIAW. | First time setting up a custom connection |
| **`/project:diagnose-connection`** | Checks an existing connection for problems and tells you exactly what's wrong in plain English. Read-only — never changes anything in your org. | When something isn't working and you want to know why |
| **`/project:update-connection`** | Adds a new response format (Time Picker, Image Cards, etc.) to an existing connection without rebuilding from scratch. Pulls your current state, shows you what's there, and merges in the change. | When you want to add a format to a connection you've already deployed |
| **`/project:test-connection`** | Sends a real message through the connection via the Agent API and shows you what came back. Walks you through External Client App setup if you don't have one. | When you want to confirm the connection actually works at runtime, not just in metadata |

All four skills work the same way: answer a few plain-English questions, the skill does the rest.

## What problem does this solve?

**Before:** You want your agent to respond with rich UI (buttons, image cards, time pickers) instead of plain text. But setting this up means writing XML metadata files by hand, understanding Salesforce deployment commands, and wiring things together across multiple config layers. Then if something breaks, the error messages are cryptic — "Cannot update record as Agent is Active" or "Surface does not exist in org" with no clear path forward. Even experienced developers find this tedious.

**After:** You run one skill, answer a few plain-English questions, and get a fully automated deploy script (for new connections), a clear diagnostic report (for broken ones), or a live test report (to confirm everything works end-to-end). No XML editing, no cryptic errors.

## Is this for me?

This tool is for you if your agent responds through the **Agent API** to a custom app — like your own website, mobile app, or portal. If you're only using Salesforce's built-in chat widget or Messaging channels, you don't need a custom connection (those are already handled for you).

## What are Custom Connections?

Custom Connections let you define your own connection type with structured response formats — so your agent can respond with carousels, buttons, image cards, time pickers, or any UI component your client app supports. Instead of plain text, your app gets structured JSON it can render however it wants.

## Quick Start

### Prerequisites

You need three things installed. You only do this once:

1. **Claude Code** — the AI tool that runs the skill
   ```bash
   npm install -g @anthropic-ai/claude-code
   ```
   Don't have npm? [Install Node.js first](https://nodejs.org/) (it includes npm).

2. **Salesforce CLI** — the command-line tool that deploys to your org
   - [Download and install here](https://developer.salesforce.com/tools/salesforcecli)

3. **An existing agent** — you need an agent already created in Agent Builder that you want to add the custom connection to.

### First time setup

After installing the Salesforce CLI, log in to your org (you only do this once):

```bash
sf org login web --alias my-org
```

This opens a browser window where you sign in with your Salesforce credentials. The `--alias` flag gives your org a short name (like "my-org") that you'll use in deploy commands later.

### Usage

```bash
git clone https://github.com/agent-connections-tools/custom-connections-skill.git
cd custom-connections-skill
claude
```

Then type:

```
/project:build-custom-connection
```

Claude will ask you:
1. What is your client called?
2. What response formats do you need?
3. Any special instructions for the agent?
4. Do you need human handoff? (optional — lets your agent transfer to a live person when it can't help)
5. Do you want a WhatsApp webhook handler? (only if you picked WhatsApp rich media in Q2)

It generates a complete deploy-ready package in `output/` with a fully automated deploy script.

### Deploy

```bash
cd output
./deploy.sh <your-org-alias> <your-agent-bundle-name>
```

**Finding your agent bundle name:** This is the developer name of your agent — not the display name you see in the UI. To find it, run:

```bash
sf data query --query "SELECT DeveloperName, MasterLabel FROM BotDefinition" --target-org my-org
```

This shows a table like:

```
DeveloperName              MasterLabel
─────────────────────────  ─────────────────────
Customer_Support_Agent     Customer Support Agent
```

Use the value from the `DeveloperName` column. Append `_v1` to it (e.g., `Customer_Support_Agent_v1`) — that's your bundle name.

> **If the deploy script says it can't find the bundle:** Your agent may have been versioned (`_v2`, `_v3`, etc.). Run this to get the exact bundle name:
> ```bash
> sf project retrieve start --metadata GenAiPlannerBundle --target-org my-org --output-dir check/ && find check/ -name "*.genAiPlannerBundle"
> ```

**What the script does:**
- Deploys your response formats and custom connection definition
- If MIAW handoff is enabled: deploys the handoff code (Apex + Flow + Custom Label)
- Retrieves your agent's existing config
- Wires the connection to your agent
- If MIAW handoff is enabled: wires the handoff action to your agent with escalation instructions baked in
- Deploys the updated config
- If WhatsApp webhook handler is enabled: generates a separate deploy script for the handler

Just deactivate your agent before running (the script will remind you) and reactivate it after. No manual wiring needed — the script handles everything.

## Quick Start: Diagnosing a broken connection

If your custom connection isn't working — the agent isn't using it, the responses come back as plain text, or the deploy failed — run the diagnostic skill to figure out what's wrong.

```bash
cd custom-connections-skill
claude
```

Then type:

```
/project:diagnose-connection
```

The skill asks three plain-English questions:
1. **What's your org alias?** (e.g., `my-org` — the name you used when you logged in with `sf org login`)
2. **What's your agent's name?** (its developer name — find it in Setup → Agents → API Name column)
3. **Which connection do you want to check?** (it lists what it found and lets you pick one or say "all")

Then it runs a series of checks and shows you a report. **The skill is read-only** — it never changes anything in your org. Safe to run on production.

### What the report looks like

```
=== Connection Health Report: Customer_Support_Agent ===

▶ Top priority: Your agent is currently active. Deactivate it before
  making any changes — Setup → Agents → Customer_Support_Agent → Deactivate.

YOUR CONNECTIONS
  1. Telephony — ✓ Standard connection, no issues
  2. Web Chat  — ✓ Standard connection, no issues
  3. Email     — ✓ Standard connection, no issues
  4. AcmePortal_ACME01 (Custom)
     ✓ Connection deployed in org
     ✓ Adaptive responses enabled
     ✓ Only 1 custom connection (within limit)
     ✓ No duplicate connections
     ✓ 2 response formats found and validated

WARNINGS (1)
  ⚠ Your agent is currently active
    What this means: Your agent is live. You cannot safely make changes
    while it's running.
    How to fix: Setup → Agents → select your agent → click Deactivate.

ISSUES (0)
  None.

=== Summary: 11 passed, 1 warning, 0 issues ===
```

Every warning and issue includes a **What this means** line (plain English) and a **How to fix** line (with Setup → navigation paths or exact commands to run). No metadata jargon.

A copy of the report is also saved as JSON to `/tmp/diagnose-report.json` — useful if you want to feed the result into a CI/CD pipeline.

### What it checks

The diagnostic looks for the most common problems with custom connections:
- The connection is wired to the agent correctly
- The custom surface exists in the org and matches what the bundle expects
- All the response formats it references are deployed
- Only one custom connection per agent (a platform limit)
- The agent is in a state where you can make changes
- Any local response format files have valid JSON

It also handles trickier cases automatically: agents with multiple versions, agents with no custom connection (it just checks the standard ones), and connections built outside the build-custom-connection skill (warns instead of crashing).

## Quick Start: Updating a connection (add a new response format)

You built a connection, deployed it, and now you want to add another response format to it — say, a Time Picker on top of the Text Choices and Image Cards you started with. Don't re-run the build skill (it scaffolds from scratch and could clobber what's already there). Use the update skill instead.

```bash
cd custom-connections-skill
claude
```

Then type:

```
/project:update-connection
```

The skill asks four plain-English questions:
1. **What's your org alias?** (e.g., `my-org`)
2. **What's your agent's name?** (its developer name)
3. **Which custom connection do you want to update?** (it lists every custom connection on your agent and lets you pick)
4. **What format do you want to add?** (it shows only formats not already on your connection — you can't accidentally pick a duplicate)

> **Important:** This skill needs your agent to be **deactivated** (same as the build and diagnose skills, opposite of the test skill). If you just ran the test skill, your agent is active — deactivate it before running this one. The skill will tell you if you forgot.

### What the skill does

1. Pulls your current connection configuration from the org
2. Shows you what's already there ("your connection currently has 2 formats: Text Choices, Image Cards")
3. Asks you to confirm — if you've added formats manually outside this skill family, the skill warns you they might be silently lost
4. Asks you to confirm the planned change ("currently 2 formats → after this: 3 formats, adding Time Picker")
5. Generates the new format, merges it with your existing formats, deploys
6. Verifies all your formats (existing + new) are still on the connection after deploy

### What the report looks like

```
=== Connection Update Report: AcmePortal_ACME01 ===

▶ Top priority: Added Time Picker to your connection. Connection now has 3 formats.

CURRENT STATE (before update)
  Connection: AcmePortal_ACME01
  Existing formats: 2
    1. AcmePortalChoices_ACME01 (Text Choices)
    2. AcmePortalChoicesWithImages_ACME01 (Choices with Images)

CHANGE
  Add: AcmePortalTimePicker_ACME01 (Time Picker)

DEPLOY
  ✓ AcmePortalTimePicker_ACME01.aiResponseFormat — created
  ✓ AcmePortal_ACME01.aiSurface — updated
  ✓ Deploy succeeded

NEW STATE (after update)
  Connection: AcmePortal_ACME01
  Total formats: 3
    1. AcmePortalChoices_ACME01 (Text Choices)
    2. AcmePortalChoicesWithImages_ACME01 (Choices with Images)
    3. AcmePortalTimePicker_ACME01 (Time Picker) — NEW

=== Summary: 1 format added, 0 modified, 0 removed ===

Next steps:
  1. Reactivate your agent (Setup → Agents → select your agent → Activate)
  2. Run /project:test-connection to verify the new format works at runtime
```

A copy is also saved as JSON to `/tmp/update-connection-report.json` with a before/after diff for use in CI/CD pipelines.

### Two safety gates before deploy

The skill has two confirmation prompts before it changes anything in your org:

1. **Detection confirmation** — after pulling your current formats, the skill shows what it found and asks "If this doesn't match what you expect, say stop." This guards against the rare case where you've added a format outside the skill family with non-standard naming, which the skill can't see and would otherwise silently drop on deploy.

2. **Change confirmation** — after generating the new format and merging it with your existing list, the skill shows the planned before/after summary and asks you to type "proceed." This is the "measure twice, cut once" gate. Nothing is deployed until you say proceed.

If you say "stop" at either gate, nothing changes in your org.

### What the skill won't do (yet)

- **Doesn't remove formats.** v1 only adds. To remove or modify a format, edit your local files and use the build skill, or wait for a future remove-format / modify-format skill.
- **Doesn't work on standard connections.** Telephony, Web Chat, Email, and Messaging don't currently support user-defined response formats. Custom connections only.
- **Doesn't preserve hand-edited surface fields.** If you edited your connection's configuration in Agent Builder beyond what the build skill produces, those edits will be lost when the skill regenerates the configuration. The skill warns you about this before deploying.

## Quick Start: Testing your connection end-to-end

The diagnose skill checks that your metadata looks correct. The test skill goes further — it sends a real message through the Agent API and shows you what came back.

```bash
cd custom-connections-skill
claude
```

Then type:

```
/project:test-connection
```

The skill asks five plain-English questions:
1. **What's your org alias?** (e.g., `my-org`)
2. **What's your agent's name?** (its developer name — same as the diagnose skill)
3. **Which connection do you want to test?** (it lists what it found and lets you pick one)
4. **Do you have an External Client App set up for the Agent API?** (if no, it walks you through the setup — see below)
5. **What message do you want to send?** (it suggests a default that's likely to trigger a structured response)

The skill is **read-mostly** — the only org-side change is a temporary session it creates and cleans up. Safe to run on production.

> **Important:** This skill needs your agent to be **active** (the opposite of the build and diagnose skills, which need it deactivated). If you just deactivated your agent to run diagnose-connection, reactivate it before running this test. The skill will tell you if you forgot.

### What the report looks like

```
=== Connection Test Report: Customer_Support_Agent ===

▶ Top priority: ✓ Connection works end-to-end. Agent responded using
  AcmePortalChoices_ACME01 format with 4 choices.

PRE-FLIGHT
  ✓ Salesforce CLI installed
  ✓ Org 'my-org' connected
  ✓ Agent 'Customer_Support_Agent' is active (v2)
  ✓ OAuth credentials valid (token issued)
  ✓ All required scopes present
  ✓ Agent API runtime available

TEST SEQUENCE
  ✓ Session created
  ✓ Turn 1: "Show me my plan options" → AcmePortalChoices_ACME01
  ✓ Response shape valid

WHAT THE AGENT RETURNED
  Format: AcmePortalChoices_ACME01
  Message: "Here are the plans we offer:"
  Choices:
    1. Starter Plan ($5/month)
    2. Basic Plan ($10/month)
    3. Professional Plan ($25/month)
    4. Enterprise Plan ($50/month)

=== Summary: 9 passed, 0 warnings, 0 issues ===
```

A copy is also saved as JSON to `/tmp/test-connection-report.json` for use in CI/CD pipelines.

### Multi-turn conversations

After each response, the skill asks "Want to send another message, or are you done?" If your first message didn't trigger a structured response (the agent might ask a clarifying question first), keep going. The skill caps the conversation at 5 turns and grades the last meaningful response.

### Don't have an External Client App?

The skill walks you through setup. Six steps in the Salesforce Setup UI — no command-line work, no XML editing. Takes about 10 minutes the first time, never again. Just answer "no" to question 4 above and follow along.

## Human Handoff (Optional)

If you answer "yes" to question 4 during the build, the skill also generates everything needed for your agent to transfer a conversation to a live person when it can't resolve an issue.

### What it does

When a customer asks something your agent can't handle (complex complaint, sensitive issue, frustrated customer), the agent hands off the entire conversation — including a summary and customer details — to a human agent in Omni-Channel. The customer sees: "Connecting you to a specialist now. They'll have the full context of our conversation."

### What gets generated

| File | Purpose |
|------|---------|
| `MIAWHandoff_<YourClient>.cls` | The code that creates the handoff session and passes context to the human agent |
| `<YourClient>_Escalate_To_MIAW.flow` | A Flow that triggers the handoff action |
| Custom Label | Stores your MIAW deployment name (so nothing is hardcoded) |

### What you need in your org first

1. **Messaging for In-App and Web** active — Setup > Messaging Settings
2. **A Messaging Deployment** — this is the channel your customers reach humans through
3. **An Omni-Channel queue** — the team that will receive handoffs (e.g., `Tier2_Support`)

### After deployment

The deploy script handles everything automatically:
- Deploys the handoff code (Apex + Flow + Custom Label)
- Wires the handoff action to your agent (available to all topics)
- Embeds the escalation instruction in the action itself (so the agent knows when to use it)

All you need to do:
1. Reactivate your agent (Setup > Agents > select your agent > Activate)
2. Test by asking your agent something it can't handle — it should hand off to a human

### Troubleshooting handoff

| Problem | Fix |
|---------|-----|
| "Queue not found" error | Check that the queue developer name in your Custom Label matches exactly (Setup > Queues) |
| Handoff doesn't route | Verify Omni-Channel is enabled and the queue has agents assigned (Setup > Omni-Channel > Routing Configuration) |
| "Messaging channel not found" | Confirm your MIAW deployment name matches the Custom Label value (Setup > Messaging Settings > Messaging Deployments) |
| Summary is cut off | The system caps summaries at 4,000 characters. Longer conversations get truncated. |

## WhatsApp Rich Media

For a full solution guide covering architecture, ECA authentication, security, and the end-to-end flow, see **[docs/WHATSAPP.md](./docs/WHATSAPP.md)**.

## Microsoft Teams Rich Media

For a full solution guide covering Azure Bot registration, Adaptive Cards, JWT authentication, and the end-to-end flow, see **[docs/TEAMS.md](./docs/TEAMS.md)**.

## WhatsApp Webhook Handler (Optional)

If you pick "WhatsApp rich media" in question 2, the skill asks a follow-up: do you also want to generate the webhook handler? This is the bridge between Meta's WhatsApp Cloud API and the Agentforce Agent API.

### Why you need a webhook handler

Meta's WhatsApp API and the Agent API don't speak the same language. The handler translates between them — receiving messages from WhatsApp, routing them to your agent, and sending the agent's structured responses back as native WhatsApp rich media (carousels, buttons, lists, images).

### Two options

| Option | Where it runs | Best for |
|--------|---------------|----------|
| **Option A: Apex** | Inside your Salesforce org (no external hosting) | Teams that work primarily in Salesforce |
| **Option B: Node.js** | Any cloud host (Heroku, Railway, Vercel) | High message volumes, teams that prefer JavaScript |

Both options do the same thing — you just pick where you want it to run.

### What gets generated

The skill generates a complete, deploy-ready webhook handler with:
- Full message translation (all 4 WhatsApp formats + plain text fallback)
- Session management (maps phone numbers to Agent API sessions)
- Meta webhook verification (the GET challenge Meta requires)
- Deploy script and step-by-step README
- Error handling with friendly user-facing messages

### After deployment

1. Deploy the custom connection first (`./deploy.sh`)
2. Then deploy the webhook (`./webhook/deploy_webhook.sh` or `./webhook/deploy_heroku.sh`)
3. Enter the webhook URL in Meta's dashboard (the README walks you through this)
4. Send a test message from WhatsApp — you should see rich media responses

### What you need first

- A Meta Business account with WhatsApp Cloud API access
- A WhatsApp Business phone number (Meta App Dashboard > WhatsApp > Getting Started)
- For Option B: a cloud hosting account (Heroku, Railway, or similar)

---

## What does success look like?

After deploying, your app receives structured JSON instead of plain text — so you can render it as cards, buttons, carousels, or whatever UI your app supports.

For example, when your app sends a message through the Agent API with `"surfaceType": "Custom"`, the agent responds with something like:

```json
{
  "message": "Here are some options for you:",
  "choices": [
    {
      "title": "Premium Plan",
      "imageUrl": "https://example.com/premium.png",
      "actionText": "Select Premium"
    },
    {
      "title": "Basic Plan",
      "imageUrl": "https://example.com/basic.png",
      "actionText": "Select Basic"
    }
  ]
}
```

Your app parses this JSON and renders it however you want. The agent still handles the conversation logic — you just control how the response looks.

**What your app needs to do:**
- Start Agent API sessions with `"surfaceConfig": {"surfaceType": "Custom"}` ([see full API examples](./GUIDE.md#step-8-use-the-custom-connection-via-agent-api))
- Parse the structured JSON responses
- Handle plain text fallbacks (the agent won't always use a format)

## What the skill creates for you

You don't need to understand these files — the skill generates them and the deploy script handles the rest. But if you're curious:

| What it is | What it does |
|------------|-------------|
| Response format definitions | Tell the agent what structured outputs are available (e.g., "text choices", "image cards") |
| Connection definition | Describes your custom connection and links it to the response formats |
| Deploy script | Automates the entire deployment — one command does everything |
| Config files | Required by the Salesforce CLI to run the deployment |

## Available Response Formats

| Format | Use Case |
|--------|----------|
| Text Choices | Present 2-7 clickable text options |
| Choices with Images | Product cards, listings with thumbnails |
| Time Picker | Let users select a time slot |
| WhatsApp Quick Reply | 1-3 tappable buttons (Meta's interactive button format) |
| WhatsApp List | Expandable list picker with sections (4-10 options) |
| WhatsApp Media Card | Image or video with caption text |
| WhatsApp Carousel | Horizontal scrollable cards (2-10 cards with images + buttons) |
| Teams Buttons | Adaptive Card with 1-6 Action.Submit buttons |
| Teams Choice Set | Dropdown or radio list (2-20 options with labels) |
| Teams Hero Card | Large image with title, subtitle, text, and buttons |
| Teams Carousel | 2-10 Adaptive Cards displayed as a carousel |
| Custom JSON | Any structured output your client can parse |

## Manual Setup (without Claude Code)

If you prefer to build manually, see the full step-by-step guide: [GUIDE.md](./GUIDE.md)

## Deployment Notes

- Use `sf project deploy start --metadata-dir` (not `--manifest`) — these metadata types aren't in the CLI registry yet
- Deactivate your agent before updating its config, then reactivate after
- Keep response formats under 7 per connection — more than that and the agent struggles to pick the right one

## Examples

The [`examples/`](./examples/) directory includes:

- **[`examples/acme-portal/`](./examples/acme-portal/)** — Pre-generated metadata for a fictional client. Browse this to see exactly what the skill produces, or deploy it to a sandbox to test the full flow.
- **[`examples/demo-response.html`](./examples/demo-response.html)** — Open in a browser to see what structured responses look like when rendered. Shows all format types side by side.
- **[`examples/verify-connection.sh`](./examples/verify-connection.sh)** — Bash script that starts an Agent API session and prints "CONNECTED" or "FAILED." Useful for CI/CD smoke tests where you want a one-line shell check. For interactive testing with a friendly report, use `/project:test-connection` instead.

```bash
./examples/verify-connection.sh <org-alias> <client-id> <client-secret> <agent-developer-name>
```

## Testing

**Easiest path — run the test skill:** `/project:test-connection` walks you through everything. It verifies the connection end-to-end, helps you set up the External Client App if you don't have one, and shows the agent's response in plain English. Recommended for first-time setup and ongoing verification.

**Verify deployment:** Open Agent Builder → Connections tab. Your custom connection should appear in the list. This confirms the metadata is deployed correctly.

**For CI/CD:** Run `examples/verify-connection.sh` (one-line bash check) or feed `/tmp/test-connection-report.json` (from the test skill) into your pipeline. Both surface the same underlying API call.

**Prerequisites for any runtime testing:**
- An External Client App (ECA) with OAuth scopes configured: `api`, `refresh_token, offline_access`, `chatbot_api`, `sfap_api` (the runtime token only contains the first, third, and fourth — `refresh_token` isn't issued for client_credentials grants)
- Client Credentials Flow enabled with a Run As user that has "API Only access" permission
- See [GUIDE.md](./GUIDE.md#step-8-use-the-custom-connection-via-agent-api) for full ECA setup steps. The test skill walks you through this if you don't have one yet.

**Agent API (the underlying mechanism):** Start a session with `"surfaceConfig": {"surfaceType": "Custom"}` in your session creation call. The Agent API injects your response formats as tools and surface instructions into the LLM context. See [GUIDE.md](./GUIDE.md) for full API examples.

**Note:** The Agent Builder preview pane does NOT support custom connections. It always uses the default channel. You must test structured responses via the Agent API.

**Important:** Your agent needs at least one topic that produces list-like responses (e.g., product options, plan choices) for the response formats to trigger. The agent only uses structured formats when it has multiple items to present — if your agent has no topics configured, it will fall back to plain text.

## Troubleshooting

**First step:** Run `/project:diagnose-connection` — it checks for all the issues below automatically and tells you exactly what's wrong and how to fix it. Skip the table below unless you want a quick reference.

| Issue | Fix |
|-------|-----|
| `RegistryError` on deploy | Use `--metadata-dir` not `--manifest` |
| `Cannot update record as Agent is Active` | Deactivate agent in Agent Builder first |
| `Surface does not exist in org` | Deploy surface/formats before updating the bundle |
| Responses come back as plain text | Ensure `surfaceConfig` is set in your session call. Agent Builder preview doesn't support custom connections — use the Agent API. |
| `duplicate value found: PlannerId` | Only one custom connection per agent is allowed. Remove existing custom surface before adding a new one. |

## License

MIT
