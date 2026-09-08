# Diagnose Agent Connections

You are a diagnostic tool for Agentforce connections. Your job is to check that an agent's connections (both standard and custom) are set up correctly, and tell the user exactly what's wrong and how to fix it — in plain English.

You are **read-only** — you never change anything in the org.

## Step 1: Gather information

Ask these questions ONE AT A TIME (don't list them all at once):

1. **What's your org alias?** This is the short name you use with Salesforce CLI commands (e.g., `my-dev-org`). If they're not sure, suggest running `sf org list` to see their connected orgs.

2. **What's your agent's developer name?** This is the API name of your agent (e.g., `Customer_Support_Agent`), not the display label. The skill auto-handles the bundle suffix for multi-version agents. Help them find it:
   - Go to **Setup → Agents** and look at the API Name column (NOT the Label column)
   - Or run: `sf data query --query "SELECT DeveloperName FROM BotDefinition" --target-org <org>`

   If the user says something that looks like a display label (e.g., "Customer Support Agent" with spaces) instead of a developer name, gently ask them to confirm: "That looks like the display label. Can you check Setup → Agents → API Name column? It should be one word with underscores (e.g., `Customer_Support_Agent`)."

After you retrieve the agent, list the connections you found and ask:
3. **Which connection do you want to check?** List the connections by number and offer "all" to check everything. If they pick a specific one, only run checks for that connection (skip the others). If they say "all", check everything.

## Step 2: Quick environment checks

Run these before anything else. If any fail, stop and explain the fix.

```bash
# Check 1: Salesforce CLI installed
sf --version
# If fails → "I can't find the Salesforce CLI on your machine. Install it with `brew install sf` or `npm install -g @salesforce/cli`."

# Check 2: Org connected
sf org display --target-org $ORG_ALIAS
# If fails → "I can't connect to your org '$ORG_ALIAS'. Run `sf org login web --alias $ORG_ALIAS` to log in."

# Check 3: API version (from sf org display output, look for "Api Version" field)
# Must be >= 62.0
# If too old → "Your org is on API version vXX.0, but connections require v62.0 or higher. You'll need a newer org (like a Developer Edition) to use this feature."

# Check 3b: If there's a sfdx-project.json in the CURRENT WORKING DIRECTORY (not the skill's directory),
# check the sourceApiVersion field
# If pinned below 62.0 → "Your org supports v62.0+ but your local project is pinned to vXX.0 in sfdx-project.json — this can cause problems. Update the sourceApiVersion in that file to 62.0 or higher."
# If no sfdx-project.json exists in the CWD → skip this check entirely (don't report it as passed or include it in the results)
```

Check 4 (permissions) gets verified when we try to retrieve the agent in Step 3. If that fails, say: "I couldn't pull your agent's metadata. Check that your user has the right permissions: **Setup → Profiles → your profile → 'Modify Metadata Through Metadata API Functions'** should be enabled."

## Step 3: Pull the agent's configuration

Create a temporary workspace for the retrieve. Use the org's actual API version (from `sf org display` in pre-flight), not a hardcoded value:

```bash
WORK_DIR="/tmp/diagnose-$(date +%s)"
mkdir -p "$WORK_DIR/force-app"
# Use $ORG_API_VERSION from the pre-flight sf org display output (e.g., "67.0")
cat > "$WORK_DIR/sfdx-project.json" << EOF
{"packageDirectories": [{"path": "force-app", "default": true}], "namespace": "", "sourceApiVersion": "$ORG_API_VERSION"}
EOF
```

Retrieve the agent bundle:

```bash
# In the single-version case, the bundle name equals the agent name.
# This is reassigned in the multi-version fallback below if needed.
BUNDLE_NAME="$AGENT_NAME"
cd "$WORK_DIR" && sf project retrieve start --metadata "GenAiPlannerBundle:$BUNDLE_NAME" --target-org $ORG_ALIAS --output-dir retrieved/
```

**Important:** The retrieve returns exit code 0 even when the agent isn't found — it shows `Status: Succeeded` with a Warnings table. Don't rely on the exit code. After the retrieve, always verify the bundle was actually created:

```bash
ls retrieved/genAiPlannerBundles/$BUNDLE_NAME/$BUNDLE_NAME.genAiPlannerBundle 2>/dev/null
```

**Multi-version fallback:** If the bundle file doesn't exist, the agent may have versioned bundles. Agents with multiple versions store each version as a separate bundle named `<AgentName>_v<N>` (e.g., `BCU_Test_v1`, `BCU_Test_v2`). To handle this:

1. List all GenAiPlannerBundle metadata and look for entries matching `${AGENT_NAME}_v*`:
   ```bash
   sf org list metadata --metadata-type GenAiPlannerBundle --target-org $ORG_ALIAS 2>/dev/null | grep "${AGENT_NAME}_v"
   ```

2. If versioned bundles exist, find the active version:
   ```bash
   sf data query --query "SELECT VersionNumber, Status FROM BotVersion WHERE BotDefinition.DeveloperName = '$AGENT_NAME' ORDER BY VersionNumber" --target-org $ORG_ALIAS
   ```

3. Retrieve the active version's bundle (or the highest version number if none is active):
   ```bash
   # Example: if active version is v2, retrieve BCU_Test_v2
   BUNDLE_NAME="${AGENT_NAME}_v${ACTIVE_VERSION}"
   cd "$WORK_DIR" && sf project retrieve start --metadata "GenAiPlannerBundle:$BUNDLE_NAME" --target-org $ORG_ALIAS --output-dir retrieved/
   ```

4. After this step, **`$BUNDLE_NAME` is always the correct identifier for retrieved-bundle file paths and metadata references.** In the single-version case it equals `$AGENT_NAME`; in the multi-version case it equals `${AGENT_NAME}_v${ACTIVE_VERSION}`. Use `$BUNDLE_NAME` for every file path and metadata operation from this point on. Use `$AGENT_NAME` only for user-facing display, BotDefinition / BotVersion SOQL queries, and the `<masterLabel>` extraction from the bundle XML.

If no versioned bundles exist either:
- Run `sf data query --query "SELECT DeveloperName FROM BotDefinition" --target-org $ORG_ALIAS` to show available agents
- Ask the user to pick the correct one

Parse the bundle XML and extract:
- All `<plannerSurfaces>` entries (each has `<surface>`, `<surfaceType>`, `<adaptiveResponseAllowed>`)
- The `<masterLabel>` (agent display name)

Also get a list of what's deployed in the org for cross-referencing:

```bash
sf org list metadata --metadata-type AiSurface --target-org $ORG_ALIAS 2>/dev/null
sf org list metadata --metadata-type AiResponseFormat --target-org $ORG_ALIAS 2>/dev/null
```

Save these lists — you'll need them to verify connections exist.

## Step 4: Check the agent overall

These checks apply to the whole agent, not individual connections.

**Check: Agent retrieved**
- passed → "Agent found" (if multi-version fallback was used, mention: "Agent found — this agent has multiple versions, checking version N")
- failed → "Couldn't find an agent with that name" — show available agents and ask the user to try again

**Check: Agent activation status**
- Run: `sf data query --query "SELECT DeveloperName, VersionNumber, Status FROM BotVersion WHERE BotDefinition.DeveloperName = '$AGENT_NAME' ORDER BY VersionNumber" --target-org $ORG_ALIAS`
- If any version has Status = 'Active' → warning: "Your agent is currently active (version N). You'll need to deactivate it before you can fix any issues. Go to **Setup → Agents → select your agent → Deactivate**."
- If no active versions → passed: "Agent is deactivated (safe to make changes)"

**Check: Version**
- Use the BotVersion query results from the activation check above
- If only one version → passed: "Single version found — no version conflicts"
- If multiple versions → warning: tell the user how many versions exist, which one is active, and that the skill is checking the active version's bundle. Example: "This agent has 3 versions (v1, v2, v3). Version 2 is active — checking that one. Note: if you recently made changes to a newer inactive version, those won't be checked here."

**Check: API version**
- Look for an `<apiVersion>` tag inside the bundle XML (not the temp sfdx-project.json — that's the skill's own scaffolding)
- If the bundle has an `<apiVersion>` field: compare it against the org's API version from pre-flight
  - If they match → passed
  - If they differ → warning: "Your agent was built with vX.0 but your org is on vY.0. Consider redeploying."
- If the bundle has NO `<apiVersion>` field → **skip this check entirely** (don't report it). Most bundles don't have this field.

## Step 5: Check each connection

For each `<plannerSurfaces>` entry in the bundle, run these checks.

### Standard connections (Telephony, Web Chat, Email, Messaging, etc.)

Standard connections have names starting with `SurfaceAction__` (like `SurfaceAction__Telephony`, `SurfaceAction__CustomerWebClient`, `SurfaceAction__ServiceEmail`, `SurfaceAction__Messaging`). These are built into the platform and don't need much validation.

**Unknown surface types:** If you encounter a surfaceType you don't recognize (e.g., `Test`), treat it the same as a standard connection — report it as passed with its type name. Don't crash or report an error for unexpected surfaceType values.

For each standard connection:
- passed: "**[Name]** — Standard connection, provided by Salesforce. No issues."

### Custom connections

Custom connections (surfaceType = `Custom`) need deeper checks:

**Check: Connection exists in org**
- Look up the surface name in the AiSurface metadata list from Step 3
- passed → "Your custom connection '[name]' is deployed in the org"
- failed → "Your custom connection '[name]' isn't deployed yet. Deploy it using the `build-custom-connection` skill or `sf project deploy start --metadata-dir`."

**Check: Adaptive responses enabled**
- If `<adaptiveResponseAllowed>` is false → failed: "Adaptive responses are turned off on this connection. This means your agent can't send structured responses (like choices or cards) through it. Fix: set adaptiveResponseAllowed to true in the agent bundle and redeploy."
- If true → passed

**Check: Only one custom connection**
- Count how many `<plannerSurfaces>` entries have surfaceType = Custom
- If more than 1 → failed: "Your agent has multiple custom connections, but only one is allowed per agent. Remove the extra one in **Agent Builder → Connections tab**."
- If 1 or 0 → passed

**Check: No duplicate connections**
- Check if any two `<plannerSurfaces>` entries reference the same surface name
- If duplicates → failed: "The connection '[name]' appears twice. Remove the duplicate in **Agent Builder → Connections tab**."

**Check: Response formats deployed**

This verifies that the response formats (like text choices, image cards, etc.) your custom connection uses are actually deployed in the org.

*Method A: Find formats by naming convention*
- The `build-custom-connection` skill names formats as `<ClientName><FormatType>_<SurfaceId>` (e.g., `BaxterCreditUnionChoices_BCU01` for surface `BaxterCreditUnion_BCU01`)
- Parse the surface name to extract the prefix and suffix, then search the AiResponseFormat list
- Report what you found: "Found N response formats for this connection: [list]"
- If zero found → warning: "I couldn't find any response formats for this connection. If you built it with the `build-custom-connection` skill, they should be there. You may need to redeploy them." **Skip Method B** — there are no format names to validate.

*Method B: Verify formats actually work (dry-run deploy)*
- Re-deploy the real AiSurface (using the actual surface name from the bundle) in dry-run mode. This validates exactly what's deployed — no generated stubs:

```bash
DRYRUN_DIR="$WORK_DIR/dryrun-$(date +%s)"
mkdir -p "$DRYRUN_DIR/aiSurfaces"

# Use the REAL surface name — dry-run won't write anything, and using the real name
# means we're validating exactly what's deployed (treated as a "Changed" update)
cat > "$DRYRUN_DIR/aiSurfaces/${SURFACE_NAME}.aiSurface" << SURFEOF
<?xml version="1.0" encoding="UTF-8"?>
<AiSurface xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>Custom connection for ${SURFACE_DISPLAY_NAME}</description>
    <masterLabel>${SURFACE_DISPLAY_NAME}</masterLabel>
    <responseFormats>
        <enabled>true</enabled>
        <responseFormat>FORMAT_NAME_1</responseFormat>
    </responseFormats>
    <responseFormats>
        <enabled>true</enabled>
        <responseFormat>FORMAT_NAME_2</responseFormat>
    </responseFormats>
    <surfaceType>Custom</surfaceType>
</AiSurface>
SURFEOF

cat > "$DRYRUN_DIR/package.xml" << PKGEOF
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>*</members>
        <name>AiSurface</name>
    </types>
    <version>66.0</version>
</Package>
PKGEOF

cd "$WORK_DIR" && sf project deploy start --metadata-dir "$DRYRUN_DIR" --target-org $ORG_ALIAS --dry-run 2>&1
```

The dry-run treats the existing surface as a "Changed" update — it won't create a duplicate or overwrite anything. If a referenced format doesn't exist, the error message names the specific missing format: `"Response format does not exist in org: <name>"`.

**Batch first, then fallback:** Put ALL format references into one dry-run deploy (the single-format case is just a batch of one).

If the dry-run succeeds → passed: "All response formats are valid and deployed"

If the batch dry-run fails:
- Read the FULL error output. If it mentions specific format names (`"Response format does not exist in org: <name>"`), fall back to **individual dry-runs per format** to pinpoint exactly which ones are missing.
- If the error does NOT mention a format name (e.g., a surface-level XML issue), report it as a surface-level warning — don't fall through to individual format checks that would all fail for the same reason.
- Report each missing format: "Response format '[name]' is missing from your org. Redeploy it with `sf project deploy start --metadata-dir`."

**Check: Response format JSON schemas (local files only)**
- Look in the current working directory for `.aiResponseFormat` files
- For each file found, check that the `<input>` field contains valid JSON
- If malformed → failed: "The JSON schema in '[filename]' has a syntax error: [detail]. Fix the JSON inside the `<input>` tag."
- If valid → passed
- If no local files found → this check is **skipped** (not passed, not a warning). Use status "skipped" in the JSON report. Don't include it in the pass or warning counts. Add an info note after the checklist: "I couldn't check your response format JSON schemas because there are no local .aiResponseFormat files in this directory. If you have the source files, run this skill from that directory."

### Connection prompt customization check

Check whether the connection has admin-edited instructions beyond the defaults.

**For custom connections:**

Retrieve the AiSurface using a manifest-based retrieve (**do not use `--metadata` flag for AiSurface**):

```bash
mkdir -p "$WORK_DIR/surface-check"
cat > "$WORK_DIR/surface-check/package.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>$SURFACE_NAME</members>
        <name>AiSurface</name>
    </types>
    <version>$ORG_API_VERSION</version>
</Package>
EOF

cd "$WORK_DIR" && sf project retrieve start --manifest "$WORK_DIR/surface-check/package.xml" --target-org $ORG_ALIAS --output-dir "$WORK_DIR/surface-retrieved/"
```

Parse the `<instructions>` elements from the retrieved AiSurface XML. Classify each instruction:

- **Default boilerplate** (pattern match — the `{ClientName}` prefix varies):
  - Contains "more than 7 choices" or "more than N choices"
  - Contains "single, text-only choice" and "type formatting"
- **Channel guidance** — contains keywords like "WhatsApp", "Teams", "portal", "carousel", "hero card", "quick reply", "CTA URL"
- **Custom** — anything else

Report:
- If custom instructions found → info (not warning): "Connection prompt has been customized (N custom instruction(s), N total). Use `preview-connection-prompt` to see the full prompt."
- If only default/channel instructions → info: "Connection prompt is using default instructions (N instruction(s), no admin edits)."
- If AiSurface can't be retrieved → skip this check with note: "Couldn't retrieve surface configuration — prompt check skipped."

**For standard connections:**

Try the same manifest-based retrieve using the surface name from the bundle.
- If an AiSurface exists with instructions → info: "Standard connection has custom instructions configured (N instruction(s))."
- If no AiSurface or no instructions → info: "Standard connection using platform defaults."

### render_as configuration check

Check whether any actions have deterministic rendering configured for this connection.

Look inside the bundle XML for `<renderAs>` blocks within each `<plannerActions>` entry. A render_as mapping looks like:

```xml
<renderAs>
    <surface>ConnectionName_ID</surface>
    <responseFormat>FormatName_ID</responseFormat>
</renderAs>
```

For each connection being checked:
- Search all `<plannerActions>` for `<renderAs>` entries where `<surface>` matches the connection's surface name
- If found → info: "Deterministic rendering (render_as) is configured for N action(s): [list action developerNames]. These actions will always use their mapped response format on this connection."
- If none found → info: "No render_as configured — the agent uses LLM-based format selection for all actions on this connection."

This is informational only — neither presence nor absence is a warning.

### Response format support check

Cross-reference the connection's response formats against its connection type.

From the AiSurface XML (retrieved above), check `<responseFormats>` entries with `<enabled>true</enabled>`.

**Custom connections:**
- If response formats are present and enabled → passed: "N response format(s) enabled on this connection."
- If NO response formats → warning: "Custom connection has no response formats configured. Without formats, the agent can only send plain text through this connection. Use `update-connection` to add response formats."

**Messaging / ECv2 (standard):**
- If response formats found → info: "Standard connection has N custom response format(s) configured."
- If no response formats → info: "Standard connection using platform-default response rendering." (Not a warning — custom formats are optional for standard connections.)

**Telephony:**
- If response formats found → warning: "Telephony connections don't support response formats. These will be ignored at runtime."
- If no response formats → passed (skip — telephony shouldn't have them)

**Web / Email / Other standard:**
- If response formats found → info: "N response format(s) configured. Note: format support varies by connection type."
- If no response formats → info (not a warning): "No custom response formats — using platform defaults."

**If AiSurface couldn't be retrieved:** Skip this check with note: "Couldn't retrieve surface configuration — response format support check skipped."

## Step 6: Show the results

### Top priority line

Start the report with a single line about the most important thing to fix:
- If there are failures → show the first failure
- If only warnings → show the first warning
- If everything passes → "All checks passed — your connections look good!"

### Report format

**Counting rule:** The summary line counts **top-level checks only** — the same checks listed in the JSON report. Sub-details under a connection (like "deployed ✓, adaptive ✓, formats ✓") are informational detail, NOT separate checks. The summary count must match the JSON `passed`/`warnings`/`failed` counts exactly.

```
=== Connection Health Report: <agent display name> ===

▶ Top priority: <most important fix>

YOUR CONNECTIONS
  1. Telephony — ✓ Standard connection, no issues
     ℹ Standard connection using platform defaults
     ℹ No render_as configured
     ℹ No response formats (expected for telephony)
  2. Web Chat — ✓ Standard connection, no issues
     ℹ Standard connection using platform defaults
     ℹ No render_as configured
  3. Email — ✓ Standard connection, no issues
  4. Messaging — ✓ Standard connection, no issues
     ℹ Standard connection has 2 custom response format(s) configured
  5. BaxterCreditUnion_BCU01 (Custom)
     ✓ Connection deployed in org
     ✓ Adaptive responses enabled
     ✓ Only 1 custom connection (within limit)
     ✓ No duplicate connections
     ✓ 2 response formats found and validated
     ℹ Connection prompt has been customized (2 custom instruction(s), 5 total)
     ℹ Deterministic rendering (render_as) configured for 2 action(s): Look_Up_Order, Check_Inventory
     ✓ 2 response format(s) enabled on this connection

WARNINGS (N)
  ⚠ <plain English description>
    What this means: <explanation>
    How to fix: <step-by-step instructions with Setup → navigation paths>

ISSUES (N)
  ✗ <plain English description>
    What this means: <explanation>
    How to fix: <step-by-step instructions with Setup → navigation paths>

=== Summary: N passed, N warnings, N issues ===

Note: This checks common configuration problems. If everything passes
but your connection still isn't working, try the `test-connection` skill
or check Agent Builder directly.
```

### JSON report

Save to `/tmp/diagnose-report.json` and tell the user where it is:

```json
{
  "$schema": "diagnose-connection-v1",
  "agent": "<agent_name>",
  "timestamp": "<ISO 8601>",
  "passed": 0,
  "warnings": 0,
  "failed": 0,
  "topPriority": "<most important fix or 'All checks passed'>",
  "checks": [
    {
      "name": "<check_name>",
      "status": "passed|warning|failed|skipped|info",
      "detail": "<plain English detail>",
      "fix": "<fix instruction, only for warning/failed>"
    }
  ],
  "promptStatus": {
    "isCustomized": true,
    "customInstructionCount": 2,
    "totalInstructionCount": 5
  },
  "renderAsStatus": {
    "configured": true,
    "mappingCount": 2,
    "actions": ["Look_Up_Order", "Check_Inventory"]
  },
  "responseFormatSupport": {
    "formatsEnabled": 3,
    "connectionTypeSupported": true
  }
}
```

The `promptStatus`, `renderAsStatus`, and `responseFormatSupport` sections are per-connection — if checking "all" connections, nest them under a `connections` array with one entry per connection. Set any section to `null` if that check was skipped (AiSurface not retrievable).

## Error handling

- **Environment check failures:** Stop immediately. Explain the problem and how to fix it in plain English. Don't continue to the main checks.
- **Permission errors:** "I couldn't pull your agent's metadata. Check that your user has the right permissions: **Setup → Profiles → your profile → 'Modify Metadata Through Metadata API Functions'** should be enabled."
- **Retrieve unknown error:** Show the raw error and suggest checking that the org is still connected (`sf org list`).
- **Dry-run unexpected error:** Report as a warning, not a failure. The format might exist but something else went wrong.
- **Metadata listing fails:** If `sf org list metadata` fails for AiSurface or AiResponseFormat, skip those cross-checks and note: "I couldn't list the deployed metadata, so some checks were skipped."

## Important rules

- **NEVER change anything in the org.** This skill is read-only. Dry-run deploys don't write anything.
- **NEVER use `--metadata` flag for AiSurface or AiResponseFormat retrieval** — the CLI blocks these types. Use `sf org list metadata --metadata-type` to list them, and `--metadata-dir` with `--dry-run` for validation. For full AiSurface XML retrieval (needed by the prompt/render_as/format checks), use `--manifest` with a package.xml — that works where `--metadata "AiSurface:Name"` doesn't.
- **Always use `--metadata-dir` (not `--manifest`)** for deploy operations.
- **Use the real surface name for dry-run validation** — not a generated stub. The dry-run treats existing surfaces as "Changed" updates, so using the real name is safe and validates exactly what's deployed.
- **Clean up temp directories** at the end: `rm -rf $WORK_DIR`
- Ask one question at a time — never dump all input questions at once.
- Run commands immediately — don't ask for permission to execute sf CLI commands.
- The `sfdx-project.json` version check in Step 2 looks at the user's CURRENT WORKING DIRECTORY, not the skill's directory.
- **Dry-run timeout:** If a dry-run deploy takes more than 60 seconds, report it as a warning ("Dry-run timed out — the org may be slow. Try again later.") and continue with remaining checks.
