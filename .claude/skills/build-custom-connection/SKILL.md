---
name: build-custom-connection
description: Build custom connection metadata for Agentforce
metadata:
  user_invocable: true
---

# Build a Custom Connection for Agentforce

> Originally from: [agent-connections-tools/custom-connections-skill](https://github.com/agent-connections-tools/custom-connections-skill)
> Author: Abhi Rathna
> Chapter mapping: Ch11 (Custom Connections), *The Agentforce Handbook*

You are a metadata generator for Agentforce Custom Connections. Your job is to gather requirements from the user and generate all the metadata files needed to deploy a custom connection to their org — including fully automated wiring to their agent.

## Your workflow

### Step 1: Gather requirements

Ask the user these questions ONE AT A TIME (don't dump them all at once):

1. **What is your client called?** (e.g., `UniversalContainers`, `AcmePortal`, `MobileApp`) — this becomes the naming prefix for all files
2. **What response formats does your client need?** Offer these common options:
   - Text choices (2-7 clickable options)
   - Choices with images (product cards, listings with thumbnails)
   - Time picker (select a time slot)
   - WhatsApp rich media (quick reply buttons, list messages, media cards, carousels — pre-built to match Meta's API)
   - Microsoft Teams rich media (Adaptive Card buttons, choice sets, hero cards, carousels — pre-built to match Bot Framework)
   - Custom JSON (describe the structure you want)
3. **Any special instructions for the agent on this connection?** (e.g., "Keep responses under 160 characters", "Always use formal tone", "Never show more than 5 choices")
4. **Do you need human handoff via MIAW?** (If the agent can't resolve an issue, should it transfer the session with full context to a human agent?) If yes, ask:
   - What is your MIAW deployment name? (Setup > Messaging Settings > Messaging Deployments)
   - What context to pass: customer name, email, conversation transcript, case number, escalation reason?
   - Should the agent summarize the conversation before handoff? (Yes = generates a summary prompt. No = passes raw transcript.)
   - What Omni-Channel queue or skill should receive the handoff? (e.g., `Tier2_Support`)

5. **(Only if user picked "WhatsApp rich media" or "Microsoft Teams rich media" in Q2) Do you want me to generate the webhook handler too?** This is the bridge between the messaging channel and the Agent API. Two options:
   - **Option A: Apex inside Salesforce** — Everything stays in your Salesforce org. No external hosting. Best if your team works primarily in Salesforce.
   - **Option B: External service (Node.js)** — A lightweight app you deploy to Heroku, Railway, or any cloud host. Best for high message volumes or teams that prefer JavaScript.

   If the user picks an option, ask the channel-specific questions:

   **For WhatsApp:**
   - What is your Meta WhatsApp Business phone number ID? (Meta App Dashboard > WhatsApp > Getting Started)
   - What verify token do you want to use? (Any string you choose — you'll enter the same one in Meta's webhook config)

   **For Teams:**
   - What is your Microsoft App ID? (Azure Portal > Bot resource > Configuration)
   - What is your Microsoft App Password? (Azure Portal > App registrations > Certificates & secrets)

**Surface ID generation:** Auto-generate the surface ID from the client name. Take the first 2-4 letters (uppercase) and append "01". Examples:
- UniversalContainers → UC01
- AcmePortal → ACME01
- MobileApp → MOBI01

Tell the user what ID you generated so they know.

### Step 2: Generate the metadata files

Create all files in a directory called `output/` in the current working directory:

```
output/
├── unpackaged/
│   ├── package.xml
│   ├── aiResponseFormats/
│   │   └── (one .aiResponseFormat file per format)
│   └── aiSurfaces/
│       └── <ClientName>_<surfaceId>.aiSurface
├── force-app/main/default/          ← (only if MIAW handoff enabled)
│   ├── classes/
│   │   ├── MIAWHandoff_<ClientName>.cls
│   │   └── MIAWHandoff_<ClientName>.cls-meta.xml
│   └── flows/
│       └── <ClientName>_Escalate_To_MIAW.flow-meta.xml
├── sfdx-project.json
├── deploy.sh
└── README.md
```

### Step 3: Generate deploy.sh

Create a fully automated deployment script that handles both stages:

```bash
#!/bin/bash
# Deploy Custom Connection: <ClientName>
# Usage: ./deploy.sh <org-alias> <agent-bundle-name>
#
# Example: ./deploy.sh my-org My_Agent_Bundle
#
# IMPORTANT: Deactivate your agent before running this script.
# Go to: Setup → Agents → your agent → Deactivate
# After the script finishes, reactivate the agent.

set -e
ORG=${1:?"Usage: ./deploy.sh <org-alias> <agent-bundle-name>"}
BUNDLE=${2:?"Usage: ./deploy.sh <org-alias> <agent-bundle-name>"}

echo ""
echo "⚠️  Make sure your agent is DEACTIVATED before continuing."
echo "   Go to: Setup → Agents → select your agent → Deactivate"
echo ""
read -rp "Press Enter when your agent is deactivated (or Ctrl+C to cancel)..."
echo ""

echo "=== Stage 1: Deploying AiResponseFormat + AiSurface ==="
sf project deploy start --metadata-dir unpackaged/ --target-org "$ORG"

echo ""
echo "=== Stage 1 complete! ==="
echo ""

echo "=== Stage 2: Wiring connection to your agent ==="
echo "Retrieving agent bundle: $BUNDLE..."

# Clean up any previous retrieval
rm -rf retrieved/

sf project retrieve start --metadata GenAiPlannerBundle:"$BUNDLE" --target-org "$ORG" --output-dir retrieved/

# Find the bundle file
BUNDLE_FILE=$(find retrieved/ -name "*.genAiPlannerBundle" | head -1)

if [ -z "$BUNDLE_FILE" ]; then
    echo "ERROR: Could not find the retrieved bundle file."
    echo "Make sure the bundle name is correct. You can find it with:"
    echo "  sf data query --query \"SELECT DeveloperName FROM BotDefinition\" --target-org $ORG"
    exit 1
fi

echo "Found bundle: $BUNDLE_FILE"

# Check if this surface is already wired
if grep -q "{ClientName}_{surfaceId}" "$BUNDLE_FILE"; then
    echo "Surface already present in bundle — skipping."
else
    # If a different Custom surface exists, warn (only one allowed per agent)
    if grep -q "<surfaceType>Custom</surfaceType>" "$BUNDLE_FILE"; then
        echo "WARNING: This agent already has a custom connection. Only one is allowed per agent."
        echo "Remove the existing custom surface in Agent Builder first, then re-run."
        exit 1
    fi
    # Add the new plannerSurfaces entry before the closing tag
    SURFACE_BLOCK='    <plannerSurfaces>\n        <adaptiveResponseAllowed>true</adaptiveResponseAllowed>\n        <callRecordingAllowed>false</callRecordingAllowed>\n        <surface>{ClientName}_{surfaceId}</surface>\n        <surfaceType>Custom</surfaceType>\n    </plannerSurfaces>'
    sed -i.bak "s|</GenAiPlannerBundle>|${SURFACE_BLOCK}\n</GenAiPlannerBundle>|" "$BUNDLE_FILE"
    rm -f "${BUNDLE_FILE}.bak"
fi

# Add package.xml for the redeploy
cat > retrieved/package.xml << PKGEOF
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>${BUNDLE}</members>
        <name>GenAiPlannerBundle</name>
    </types>
    <version>66.0</version>
</Package>
PKGEOF

echo "Deploying updated bundle..."
sf project deploy start --metadata-dir retrieved/ --target-org "$ORG" --wait 5

echo ""
echo "=== Done! ==="
echo ""
echo "Now reactivate your agent:"
echo "  Setup → Agents → select your agent → Activate"
echo ""
echo "Verify in Agent Builder → Connections tab that your connection appears."
echo "Test structured responses via the Agent API."
```

Make the script executable after creating it.

**Important:** Replace `{ClientName}_{surfaceId}` in the sed command with the actual values from the user's input.

### Step 4: Stage 2 automation details

After generating and deploying the Stage 1 files, guide the user through Stage 2:

1. **Ask:** "What's your agent's developer name?" — help them find it:
   - Option A: Setup → Agents, look at the API name
   - Option B: Run `sf data query --query "SELECT DeveloperName FROM BotDefinition" --target-org <org>`
2. The deploy.sh script handles the rest automatically — it retrieves the bundle, adds the plannerSurfaces entry, and deploys.
3. Remind the user:
   - Deactivate the agent before running deploy.sh
   - Reactivate after it completes

### Step 5: Generate README.md

Create a short README with:
- What this connection does (1-2 sentences)
- Prerequisites (Salesforce CLI, authenticated org)
- How to deploy (`./deploy.sh <org-alias> <agent-bundle-name>`)
- How to verify (Agent Builder → Connections tab. Test structured responses via Agent API.)
- The response format schemas this connection supports

## Metadata templates

Use these exact XML structures. Replace placeholders with the user's values.

### package.xml

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>*</members>
        <name>AiSurface</name>
    </types>
    <types>
        <members>*</members>
        <name>AiResponseFormat</name>
    </types>
    <version>66.0</version>
</Package>
```

### AiResponseFormat — Text Choices

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AiResponseFormat xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>A response action for {ClientName}. Use this to prompt the user to select one of many available text choices when the number of choices is GREATER THAN 1 and LESSER THAN 8.</description>
    <input>{"type":"object","properties":{"message":{"type":"string","description":"A brief message introducing the choices"},"choices":{"type":"array","items":{"type":"string"}}},"required":["message","choices"]}</input>
    <instructions>
        <instruction>Always use {ClientName}Choices when showing choice text responses with GREATER THAN 1 choice and LESS THAN 8 choices to the user.</instruction>
        <sortOrder>1</sortOrder>
    </instructions>
    <masterLabel>{Client Display Name} Chat Choice Response</masterLabel>
</AiResponseFormat>
```

### AiResponseFormat — Choices with Images

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AiResponseFormat xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>A response action for {ClientName}. Use this to prompt the user to select one of many choices with accompanying images, such as product listings.</description>
    <input>{"type":"object","properties":{"message":{"type":"string","description":"A brief message introducing the choices"},"choices":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"imageUrl":{"type":"string"},"actionText":{"type":"string"}},"required":["title","imageUrl","actionText"]}}},"required":["message","choices"]}</input>
    <instructions>
        <instruction>Always use {ClientName}ChoicesWithImages when showing choices with images with GREATER THAN 1 choice and LESS THAN 8 choices to the user.</instruction>
        <sortOrder>2</sortOrder>
    </instructions>
    <masterLabel>{Client Display Name} Chat Choice With Images</masterLabel>
</AiResponseFormat>
```

### AiResponseFormat — Time Picker

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AiResponseFormat xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>A response action for {ClientName}. Use this to prompt the user to select a time using a time picker component.</description>
    <input>{"type":"object","properties":{"type":{"const":"section"},"text":{"type":"object","properties":{"type":{"const":"mrkdwn"},"text":{"type":"string"}},"required":["type","text"],"additionalProperties":false},"accessory":{"type":"object","properties":{"type":{"const":"timepicker"},"initial_time":{"type":"string","pattern":"^(?:[01]\\d|2[0-3]):[0-5]\\d$"},"placeholder":{"type":"object","properties":{"type":{"const":"plain_text"},"text":{"type":"string"},"emoji":{"type":"boolean"}},"required":["type","text","emoji"],"additionalProperties":false},"action_id":{"type":"string"}},"required":["type","initial_time","placeholder","action_id"],"additionalProperties":false}},"required":["type","text","accessory"],"additionalProperties":false}</input>
    <instructions>
        <instruction>Use {ClientName}TimePicker when you need the user to select a specific time.</instruction>
        <sortOrder>3</sortOrder>
    </instructions>
    <masterLabel>{Client Display Name} Chat Time Picker</masterLabel>
</AiResponseFormat>
```

### AiResponseFormat — WhatsApp Quick Reply Buttons

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AiResponseFormat xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>A response action for {ClientName} on WhatsApp. Use this to show the user up to 3 quick-reply buttons. Each button has a short label the user can tap to respond instantly.</description>
    <input>{"type":"object","properties":{"body":{"type":"string","description":"Main message text (max 1024 chars)","maxLength":1024},"header":{"type":"string","description":"Optional header text (max 60 chars)","maxLength":60},"footer":{"type":"string","description":"Optional footer text (max 60 chars)","maxLength":60},"buttons":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string","description":"Unique button identifier"},"title":{"type":"string","description":"Button label (max 20 chars)","maxLength":20}},"required":["id","title"]},"minItems":1,"maxItems":3}},"required":["body","buttons"]}</input>
    <instructions>
        <instruction>Use {ClientName}WhatsAppButtons when presenting 1 to 3 short options the user can tap to reply. Do NOT use this for more than 3 options — use {ClientName}WhatsAppList instead.</instruction>
        <sortOrder>4</sortOrder>
    </instructions>
    <masterLabel>{Client Display Name} WhatsApp Quick Reply</masterLabel>
</AiResponseFormat>
```

### AiResponseFormat — WhatsApp List Message

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AiResponseFormat xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>A response action for {ClientName} on WhatsApp. Use this to show a list picker with sections and rows. The user taps a button to expand the list and selects one option. Best for 4-10 options grouped into categories.</description>
    <input>{"type":"object","properties":{"body":{"type":"string","description":"Main message text (max 1024 chars)","maxLength":1024},"header":{"type":"string","description":"Optional header text (max 60 chars)","maxLength":60},"footer":{"type":"string","description":"Optional footer text (max 60 chars)","maxLength":60},"buttonText":{"type":"string","description":"CTA button label that opens the list (max 20 chars)","maxLength":20},"sections":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string","description":"Section heading (max 24 chars)","maxLength":24},"rows":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string","description":"Unique row identifier"},"title":{"type":"string","description":"Row title (max 24 chars)","maxLength":24},"description":{"type":"string","description":"Optional row description (max 72 chars)","maxLength":72}},"required":["id","title"]}}},"required":["title","rows"]},"minItems":1,"maxItems":10}},"required":["body","buttonText","sections"]}</input>
    <instructions>
        <instruction>Use {ClientName}WhatsAppList when presenting 4 or more options, or when options need grouping into categories. Maximum 10 rows total across all sections. Do NOT use quick reply buttons for more than 3 options.</instruction>
        <sortOrder>5</sortOrder>
    </instructions>
    <masterLabel>{Client Display Name} WhatsApp List</masterLabel>
</AiResponseFormat>
```

### AiResponseFormat — WhatsApp Media Card

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AiResponseFormat xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>A response action for {ClientName} on WhatsApp. Use this to send an image or video with a caption. Best for product photos, how-to images, or video explanations.</description>
    <input>{"type":"object","properties":{"mediaType":{"type":"string","enum":["image","video"],"description":"Type of media to send"},"url":{"type":"string","description":"HTTPS URL to the media file (image: JPEG/PNG max 5MB, video: MP4 max 16MB)"},"caption":{"type":"string","description":"Caption text below the media (max 1024 chars)","maxLength":1024}},"required":["mediaType","url","caption"]}</input>
    <instructions>
        <instruction>Use {ClientName}WhatsAppMedia when sharing a product image, screenshot, document preview, or video with the user. Always include a descriptive caption.</instruction>
        <sortOrder>6</sortOrder>
    </instructions>
    <masterLabel>{Client Display Name} WhatsApp Media</masterLabel>
</AiResponseFormat>
```

### AiResponseFormat — WhatsApp Carousel

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AiResponseFormat xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>A response action for {ClientName} on WhatsApp. Use this to show a horizontal scrollable carousel of 2-10 cards. Each card has an image, body text, and up to 2 buttons. Best for product comparisons, plan options, or browsing catalogs.</description>
    <input>{"type":"object","properties":{"body":{"type":"string","description":"Introductory message above the carousel (max 1024 chars)","maxLength":1024},"cards":{"type":"array","items":{"type":"object","properties":{"imageUrl":{"type":"string","description":"HTTPS URL to card image (JPEG/PNG, max 5MB)"},"bodyText":{"type":"string","description":"Card body text (max 160 chars)","maxLength":160},"buttons":{"type":"array","items":{"type":"object","properties":{"type":{"type":"string","enum":["quick_reply","url"],"description":"Button type"},"title":{"type":"string","description":"Button label (max 25 chars)","maxLength":25},"payload":{"type":"string","description":"Callback payload for quick_reply, or URL for url type"}},"required":["type","title","payload"]},"minItems":1,"maxItems":2}},"required":["imageUrl","bodyText","buttons"]},"minItems":2,"maxItems":10}},"required":["body","cards"]}</input>
    <instructions>
        <instruction>Use {ClientName}WhatsAppCarousel when comparing multiple items side by side (products, plans, options). Minimum 2 cards, maximum 10. Each card MUST have an image. Use quick reply buttons for card-level selections.</instruction>
        <sortOrder>7</sortOrder>
    </instructions>
    <masterLabel>{Client Display Name} WhatsApp Carousel</masterLabel>
</AiResponseFormat>
```

### AiSurface

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AiSurface xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>Custom connection for {Client Display Name}.</description>
    <instructions>
        <instruction>{User's custom instruction 1}</instruction>
        <sortOrder>1</sortOrder>
    </instructions>
    <instructions>
        <instruction>Do not use response formats where the response contains more than 7 choices.</instruction>
        <sortOrder>2</sortOrder>
    </instructions>
    <instructions>
        <instruction>Do not use any of the {ClientName}* type formatting where the response contains only a single, text-only choice without images or URLs.</instruction>
        <sortOrder>3</sortOrder>
    </instructions>
    <masterLabel>{Client Display Name}</masterLabel>
    <responseFormats>
        <enabled>true</enabled>
        <responseFormat>{ClientName}Choices_{surfaceId}</responseFormat>
    </responseFormats>
    <!-- Add more responseFormats entries for each format the user requested -->
    <surfaceType>Custom</surfaceType>
</AiSurface>
```

### sfdx-project.json

```json
{
  "packageDirectories": [{ "path": "unpackaged", "default": true }, { "path": "force-app" }],
  "namespace": "",
  "sfdcLoginUrl": "https://login.salesforce.com",
  "sourceApiVersion": "66.0"
}
```

Note: If MIAW handoff is NOT enabled, omit the `{ "path": "force-app" }` entry (no force-app directory exists).

## MIAW Handoff (generated only if user said yes to question 4)

### Apex Class: MIAWHandoff_<ClientName>.cls

Generate an Apex class that:

1. Is annotated with `@InvocableMethod` (callable from agent escalation action)
2. Accepts these inputs via an inner `HandoffRequest` class with `@InvocableVariable`:
   - `conversationId` (String, required) — Agent API session ID
   - `customerName` (String, required)
   - `customerEmail` (String)
   - `escalationReason` (String, required)
   - `conversationSummary` (String) — truncated to 4000 chars max
   - `routingTarget` (String, required) — Omni-Channel queue/skill name
   - Any custom fields the user specified
3. Returns a `HandoffResult` inner class with:
   - `messagingSessionId` (String)
   - `confirmationMessage` (String)
   - `success` (Boolean)
4. Implementation:
   - Creates a MessagingSession record linked to the user's MIAW deployment
   - Populates pre-chat fields from input variables
   - Stores conversation context (summary or transcript) in the session
   - Routes to the specified Omni-Channel queue/skill
   - Returns confirmation: "Connecting you to a specialist now. They'll have the full context of our conversation."
5. Error handling: if session creation fails, return `success=false` with message "I'm having trouble connecting you to a specialist. Please try again or contact us directly."

Use this template:

```apex
public class MIAWHandoff_{ClientName} {

    public class HandoffRequest {
        @InvocableVariable(required=true label='Conversation ID')
        public String conversationId;

        @InvocableVariable(required=true label='Customer Name')
        public String customerName;

        @InvocableVariable(label='Customer Email')
        public String customerEmail;

        @InvocableVariable(required=true label='Escalation Reason')
        public String escalationReason;

        @InvocableVariable(label='Conversation Summary')
        public String conversationSummary;

        @InvocableVariable(required=true label='Routing Target')
        public String routingTarget;
    }

    public class HandoffResult {
        @InvocableVariable
        public String messagingSessionId;

        @InvocableVariable
        public String confirmationMessage;

        @InvocableVariable
        public Boolean success;
    }

    @InvocableMethod(label='Hand Off to Human Agent via MIAW'
                     description='Transfers the current Agentforce session to a human agent through Messaging for In-App and Web, passing full conversation context.')
    public static List<HandoffResult> executeHandoff(List<HandoffRequest> requests) {
        List<HandoffResult> results = new List<HandoffResult>();
        for (HandoffRequest req : requests) {
            HandoffResult result = new HandoffResult();
            try {
                // Get the messaging channel
                MessagingChannel channel = [
                    SELECT Id FROM MessagingChannel
                    WHERE DeveloperName = :Label.MIAW_Deployment_{ClientName}
                    LIMIT 1
                ];

                // Create messaging session with pre-chat context
                MessagingSession session = new MessagingSession(
                    MessagingChannelId = channel.Id,
                    Status = 'New'
                );
                insert session;

                // Store conversation context
                ConversationEntry entry = new ConversationEntry(
                    ConversationId = session.ConversationId,
                    EntryType = 'Text',
                    Message = 'HANDOFF CONTEXT\n'
                        + 'Customer: ' + req.customerName + '\n'
                        + 'Email: ' + (req.customerEmail != null ? req.customerEmail : 'N/A') + '\n'
                        + 'Reason: ' + req.escalationReason + '\n\n'
                        + 'Conversation Summary:\n'
                        + (req.conversationSummary != null
                            ? req.conversationSummary.left(4000)
                            : 'No summary available')
                );
                insert entry;

                // Route to queue
                SkillBasedRoutingWork work = new SkillBasedRoutingWork();
                // Route based on queue name from Custom Label
                Group queue = [
                    SELECT Id FROM Group
                    WHERE Type = 'Queue' AND DeveloperName = :req.routingTarget
                    LIMIT 1
                ];
                session.OwnerId = queue.Id;
                update session;

                result.messagingSessionId = session.Id;
                result.confirmationMessage = 'Connecting you to a specialist now. They\'ll have the full context of our conversation.';
                result.success = true;
            } catch (Exception e) {
                result.success = false;
                result.confirmationMessage = 'I\'m having trouble connecting you to a specialist. Please try again or contact us directly.';
            }
            results.add(result);
        }
        return results;
    }
}
```

### Apex meta.xml

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

### Flow: <ClientName>_Escalate_To_MIAW

Generate an autolaunched Flow that:
1. Receives input variables: conversationId, customerName, customerEmail, escalationReason, conversationSummary
2. Sets the routingTarget from a constant (the queue name the user specified)
3. Calls the MIAWHandoff_{ClientName} invocable action
4. Returns the confirmationMessage to the caller

### Deploy script addition

When MIAW handoff is enabled, add this block to deploy.sh AFTER Stage 1 but BEFORE the Stage 2 bundle wiring:

```bash
echo "=== Deploying MIAW Handoff Action ==="
sf project deploy start --source-dir force-app --target-org "$ORG" --wait 10
echo "MIAW Handoff code deployed."
echo ""
```

Then, in the Stage 2 bundle-wiring section (AFTER retrieving the bundle and AFTER adding plannerSurfaces for the custom connection), add the handoff action to the bundle:

```bash
# === Wire MIAW handoff action to agent ===
echo "Wiring MIAW handoff action to agent..."

# Check if the handoff action is already wired
if grep -q "{ClientName}_Escalate_To_MIAW" "$BUNDLE_FILE"; then
    echo "MIAW handoff action already wired — skipping."
else
    # Create the action block and instruction to inject
    HANDOFF_BLOCK_FILE=$(mktemp)
    cat > "$HANDOFF_BLOCK_FILE" << 'HANDOFFEOF'
    <localActionLinks>
        <genAiFunctionName>MIAWHandoff_{ClientName}</genAiFunctionName>
    </localActionLinks>
    <plannerActions>
        <fullName>MIAWHandoff_{ClientName}</fullName>
        <description>Transfers the conversation to a human agent via Messaging for In-App and Web. Use this when: (1) you cannot resolve the issue after two attempts, (2) the customer explicitly asks for a human, or (3) the issue requires human judgment (billing disputes, complaints, policy exceptions). Pass the full conversation context including customer name, email, escalation reason, and a summary of what was discussed.</description>
        <developerName>MIAWHandoff_{ClientName}</developerName>
        <invocationTarget>{ClientName}_Escalate_To_MIAW</invocationTarget>
        <invocationTargetType>flow</invocationTargetType>
        <isConfirmationRequired>false</isConfirmationRequired>
        <isIncludeInProgressIndicator>true</isIncludeInProgressIndicator>
        <localDeveloperName>MIAWHandoff_{ClientName}</localDeveloperName>
        <masterLabel>Hand Off to Human Agent via MIAW</masterLabel>
    </plannerActions>
HANDOFFEOF

    # Insert before </GenAiPlannerBundle> using awk (portable across macOS/Linux)
    awk -v blockfile="$HANDOFF_BLOCK_FILE" '
        /<\/GenAiPlannerBundle>/ {
            while ((getline line < blockfile) > 0) print line
            close(blockfile)
        }
        { print }
    ' "$BUNDLE_FILE" > "${BUNDLE_FILE}.tmp" && mv "${BUNDLE_FILE}.tmp" "$BUNDLE_FILE"
    rm -f "$HANDOFF_BLOCK_FILE"
    echo "MIAW handoff action wired to agent."
fi
```

Also generate input/output schema files for the action. Create these in the retrieved bundle directory:

```
retrieved/genAiPlannerBundles/<BundleName>/localActions/MIAWHandoff_{ClientName}/input/schema.json
retrieved/genAiPlannerBundles/<BundleName>/localActions/MIAWHandoff_{ClientName}/output/schema.json
```

**input/schema.json:**
```json
{
  "type": "object",
  "properties": {
    "conversationId": { "type": "string", "description": "The current session ID" },
    "customerName": { "type": "string", "description": "Customer's full name" },
    "customerEmail": { "type": "string", "description": "Customer's email address" },
    "escalationReason": { "type": "string", "description": "Why the conversation is being escalated" },
    "conversationSummary": { "type": "string", "description": "Summary of the conversation so far" }
  },
  "required": ["conversationId", "customerName", "escalationReason"]
}
```

**output/schema.json:**
```json
{
  "type": "object",
  "properties": {
    "confirmationMessage": { "type": "string", "description": "Message to show the customer" },
    "success": { "type": "boolean", "description": "Whether the handoff succeeded" }
  }
}
```

The deploy script should create these schema directories and files dynamically during the bundle-wiring stage.

At the end of the deploy script (when MIAW is enabled), replace the manual post-deployment steps with:

```bash
echo ""
echo "=== Done! ==="
echo ""
echo "Now reactivate your agent:"
echo "  Setup → Agents → select your agent → Activate"
echo ""
echo "What was automated:"
echo "  ✓ Custom connection deployed and wired"
echo "  ✓ MIAW handoff code deployed (Apex + Flow + Custom Label)"
echo "  ✓ Handoff action wired to your agent (available to all topics)"
echo "  ✓ Escalation instruction embedded in the action description"
echo ""
echo "Verify:"
echo "  1. Reactivate agent: Setup → Agents → select your agent → Activate"
echo "  2. Messaging is active: Setup → Messaging Settings"
echo "  3. Omni-Channel routing: Setup → Omni-Channel → Routing Configuration"
echo "  4. Test: ask your agent something it can't handle — it should hand off to a human"
```

### Custom Labels (generated alongside)

Generate a Custom Label for the MIAW deployment name so it's not hardcoded:
- Label name: `MIAW_Deployment_{ClientName}`
- Value: the deployment name the user provided
- Category: `Agentforce`

### README addition

Add a "Human Handoff" section to the README:
- What it does (transfers session context to human via MIAW)
- How it's wired (automatically — the deploy script adds the action to your agent and embeds the escalation instruction)
- What context the human agent sees
- How to test (trigger an escalation, verify Omni-Channel receives the session)
- Troubleshooting: queue not found, messaging channel not active, conversation summary too long

---

## Important rules

- ALWAYS use `--metadata-dir` for deployment, never `--manifest` (these metadata types aren't in the CLI registry)
- File names must match the developer name inside the XML
- The `input` field in AiResponseFormat must be valid JSON on a single line (no pretty-printing inside the XML tag)
- Keep response formats under 7 per connection
- Only one custom connection per agent — if the agent already has a surfaceType=Custom entry, replace it rather than adding a second one
- Never create a new GenAiPlannerBundle — always add plannerSurfaces to the existing bundle
- Auto-generate the surface ID from the client name (first 3-4 uppercase letters + "01") — don't ask the user for it
- Run the deploy script immediately after generating files (user has pre-approved this)
- If the user provides a custom JSON schema for a response format, validate it's proper JSON before writing it into the XML
- MIAW handoff: Do NOT hardcode org-specific values. Use Custom Labels for deployment name and queue name.
- MIAW handoff: Truncate conversation summary to 4000 characters max (field limit)
- MIAW handoff: The Apex class must handle bulk (list of requests) even though most calls will be single
- WhatsApp: When user picks "WhatsApp rich media," generate ALL 4 WhatsApp formats (Quick Reply, List, Media, Carousel). Don't ask which ones — they work as a set.
- WhatsApp: Add these surface instructions: "Use WhatsApp quick reply buttons for 1-3 options. Use WhatsApp list for 4-10 options. Use WhatsApp media when sharing images or videos. Use WhatsApp carousel for product comparisons. Respect Meta character limits: button text 20 chars, list row title 24 chars, body text 1024 chars."
- WhatsApp: If user picks a webhook handler option, generate the handler from templates. If they skip Q5, don't generate the webhook — they'll build it themselves.
- Teams: When user picks "Microsoft Teams rich media," generate ALL 4 Teams formats (Buttons, ChoiceSet, HeroCard, Carousel). Don't ask which ones — they work as a set.
- Teams: Add these surface instructions: "Use Teams buttons for 1-6 options. Use Teams choice set for 7+ options or when options need labels. Use Teams hero card when sharing a single product or visual. Use Teams carousel for product comparisons. Button labels max 40 chars."
- Teams: If user picks a webhook handler option, generate the handler from templates. If they skip Q5, don't generate the webhook — they'll build it themselves.

---

## WhatsApp Webhook Handler (generated only if user said yes to question 5)

When the user picks a webhook handler option, generate the handler code in `output/webhook/`.

### Option A: Apex Inside Salesforce

Use the templates in `templates/whatsapp-webhook/option-a-apex/` as the basis. Copy them to `output/webhook/` and replace all `{ClientName}` and `{surfaceId}` placeholders with actual values. Also replace the verify token and phone number ID in the Custom Metadata template.

Generated files in `output/webhook/`:
```
webhook/
├── classes/
│   ├── WhatsAppWebhook_<ClientName>.cls
│   └── WhatsAppWebhook_<ClientName>.cls-meta.xml
├── objects/
│   └── WhatsApp_Session__c.object-meta.xml
├── sites/
│   └── WhatsAppWebhookSite.site-meta.xml
├── deploy_webhook.sh
└── README.md
```

The deploy script deploys the Apex class, custom object, and site config. The README walks through:
1. Creating a Meta App and getting credentials
2. Setting up Named Credentials in Salesforce
3. Configuring the Salesforce Site
4. Entering the webhook URL in Meta's dashboard
5. Testing end-to-end

### Option B: External Service (Node.js)

Use the templates in `templates/whatsapp-webhook/option-b-node/` as the basis. Copy them to `output/webhook/` and replace `{ClientName}` and `{surfaceId}` placeholders.

Generated files in `output/webhook/`:
```
webhook/
├── index.js
├── package.json
├── .env.example
├── Procfile
├── deploy_heroku.sh
└── README.md
```

The README walks through:
1. Creating a Meta App and getting credentials
2. Getting Salesforce ECA credentials (Consumer Key + Secret)
3. Deploying to Heroku/Railway (one command)
4. Configuring the webhook URL in Meta's dashboard
5. Testing end-to-end

### Key rules for webhook generation

- Replace ALL `{ClientName}` and `{surfaceId}` placeholders in the template files
- For Option A: also generate a Custom Metadata Type record with the user's verify token and phone number ID
- For Option B: populate the `.env.example` with the user's values as comments (never put actual secrets in committed files)
- The response format translation function (`convertToMetaFormat` / `translateToWhatsApp`) must handle all 4 WhatsApp formats plus plain text fallback
- After generating, tell the user: "I've generated the webhook handler. Deploy the connection first (`./deploy.sh`), then deploy the webhook (`./webhook/deploy_webhook.sh` or `./webhook/deploy_heroku.sh`)."

---

## Microsoft Teams Webhook Handler (generated only if user picked Teams and said yes to question 5)

When the user picks a Teams webhook handler option, generate the handler code in `output/webhook/`.

### Option A: Apex Inside Salesforce

Use the templates in `templates/teams-webhook/option-a-apex/` as the basis. Copy them to `output/webhook/` and replace all `{ClientName}` and `{surfaceId}` placeholders with actual values.

Generated files in `output/webhook/`:
```
webhook/
├── classes/
│   ├── TeamsWebhook_<ClientName>.cls
│   └── TeamsWebhook_<ClientName>.cls-meta.xml
├── objects/
│   └── Teams_Session__c.object-meta.xml
├── deploy_webhook.sh
└── README.md
```

The deploy script deploys the Apex class, custom object, and Remote Site Settings. The README walks through:
1. Creating an Azure Bot resource
2. Getting Microsoft App ID and Password
3. Setting up Named Credentials in Salesforce
4. Configuring the Salesforce Site
5. Setting the messaging endpoint in Azure Bot config
6. Installing the bot in Teams
7. Testing end-to-end

### Option B: External Service (Node.js)

Use the templates in `templates/teams-webhook/option-b-node/` as the basis. Copy them to `output/webhook/` and replace `{ClientName}` and `{surfaceId}` placeholders.

Generated files in `output/webhook/`:
```
webhook/
├── index.js
├── package.json
├── .env.example
├── Procfile
├── deploy_heroku.sh
└── README.md
```

The README walks through:
1. Creating an Azure Bot resource and getting App ID/Password
2. Getting Salesforce ECA credentials (Consumer Key + Secret)
3. Deploying to Heroku/Railway (one command)
4. Setting the messaging endpoint in Azure Bot config
5. Installing the bot in Teams
6. Testing end-to-end

### Key rules for Teams webhook generation

- Replace ALL `{ClientName}` and `{surfaceId}` placeholders in the template files
- For Option A: set up Named Credentials for both Microsoft (Bot Framework token endpoint) and Salesforce (Agent API)
- For Option B: populate the `.env.example` with the user's Microsoft App ID as a comment (never put the App Password in committed files)
- The response format translation function must handle all 4 Teams formats (Buttons, ChoiceSet, HeroCard, Carousel) plus plain text fallback
- Teams replies use Adaptive Card attachments: `{ type: "message", attachments: [{ contentType: "application/vnd.microsoft.card.adaptive", content: {...} }] }`
- After generating, tell the user: "I've generated the webhook handler. Deploy the connection first (`./deploy.sh`), then deploy the webhook (`./webhook/deploy_webhook.sh` or `./webhook/deploy_heroku.sh`)."

