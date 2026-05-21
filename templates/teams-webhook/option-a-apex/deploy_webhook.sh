#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# deploy_webhook.sh
#
# Deploys the Microsoft Teams webhook handler to your Salesforce org.
# This script uses the Salesforce CLI (sf) to push the Apex class,
# custom object, and related metadata.
#
# Prerequisites:
#   1. Salesforce CLI installed (https://developer.salesforce.com/tools/salesforcecli)
#   2. Authenticated to your target org (run: sf org login web)
#   3. The org has Agent API enabled and a bot/agent configured
#
# Usage:
#   chmod +x deploy_webhook.sh
#   ./deploy_webhook.sh [org-alias]
#
# Examples:
#   ./deploy_webhook.sh              (uses default org)
#   ./deploy_webhook.sh my-sandbox   (deploys to specific org)
# ──────────────────────────────────────────────────────────────────────────────

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ORG_ALIAS=${1:-""}
TARGET_FLAG=""
if [ -n "$ORG_ALIAS" ]; then
    TARGET_FLAG="--target-org $ORG_ALIAS"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Teams Webhook Deployment for {ClientName}           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Check prerequisites ─────────────────────────────────────────────
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v sf &> /dev/null; then
    echo -e "${RED}Error: Salesforce CLI (sf) is not installed.${NC}"
    echo "Install it from: https://developer.salesforce.com/tools/salesforcecli"
    exit 1
fi

# Check if authenticated to an org
if ! sf org display $TARGET_FLAG 2>/dev/null | grep -q "Connected Status"; then
    echo -e "${YELLOW}You may not be authenticated. Attempting deployment anyway...${NC}"
fi

echo -e "${GREEN}Prerequisites OK${NC}"
echo ""

# ─── Step 2: Create project structure for deployment ──────────────────────────
echo -e "${YELLOW}Preparing deployment package...${NC}"

DEPLOY_DIR=$(mktemp -d)
CLASSES_DIR="$DEPLOY_DIR/force-app/main/default/classes"
OBJECTS_DIR="$DEPLOY_DIR/force-app/main/default/objects/Teams_Session__c"

mkdir -p "$CLASSES_DIR"
mkdir -p "$OBJECTS_DIR/fields"

# Copy Apex class
cp "$(dirname "$0")/TeamsWebhook_{ClientName}.cls" "$CLASSES_DIR/"
cp "$(dirname "$0")/TeamsWebhook_{ClientName}.cls-meta.xml" "$CLASSES_DIR/"

# Create the object definition
cat > "$OBJECTS_DIR/Teams_Session__c.object-meta.xml" << 'OBJEOF'
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <label>Teams Session</label>
    <pluralLabel>Teams Sessions</pluralLabel>
    <nameField>
        <label>Session Name</label>
        <type>AutoNumber</type>
        <displayFormat>TMS-{0000000}</displayFormat>
    </nameField>
    <deploymentStatus>Deployed</deploymentStatus>
    <sharingModel>ReadWrite</sharingModel>
    <description>Maps Microsoft Teams conversation IDs to Agentforce Agent API session IDs.</description>
</CustomObject>
OBJEOF

# Create field definitions
cat > "$OBJECTS_DIR/fields/Conversation_Id__c.field-meta.xml" << 'FLDEOF'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Conversation_Id__c</fullName>
    <label>Conversation ID</label>
    <type>Text</type>
    <length>255</length>
    <required>true</required>
    <unique>true</unique>
    <externalId>true</externalId>
    <description>Teams conversation ID from Bot Framework Activity</description>
</CustomField>
FLDEOF

cat > "$OBJECTS_DIR/fields/Agent_Session_Id__c.field-meta.xml" << 'FLDEOF'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Agent_Session_Id__c</fullName>
    <label>Agent Session ID</label>
    <type>Text</type>
    <length>255</length>
    <required>true</required>
    <externalId>false</externalId>
    <description>Session ID from the Agentforce Agent API</description>
</CustomField>
FLDEOF

cat > "$OBJECTS_DIR/fields/Last_Sequence_Id__c.field-meta.xml" << 'FLDEOF'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Last_Sequence_Id__c</fullName>
    <label>Last Sequence ID</label>
    <type>Number</type>
    <precision>10</precision>
    <scale>0</scale>
    <required>true</required>
    <defaultValue>1</defaultValue>
    <description>Message sequence counter for the Agent API</description>
</CustomField>
FLDEOF

cat > "$OBJECTS_DIR/fields/Last_Activity__c.field-meta.xml" << 'FLDEOF'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Last_Activity__c</fullName>
    <label>Last Activity</label>
    <type>DateTime</type>
    <required>true</required>
    <description>Timestamp of last message in this session</description>
</CustomField>
FLDEOF

cat > "$OBJECTS_DIR/fields/User_Name__c.field-meta.xml" << 'FLDEOF'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>User_Name__c</fullName>
    <label>User Name</label>
    <type>Text</type>
    <length>255</length>
    <required>false</required>
    <externalId>false</externalId>
    <description>Display name of the Teams user</description>
</CustomField>
FLDEOF

cat > "$OBJECTS_DIR/fields/User_Email__c.field-meta.xml" << 'FLDEOF'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>User_Email__c</fullName>
    <label>User Email</label>
    <type>Text</type>
    <length>255</length>
    <required>false</required>
    <externalId>false</externalId>
    <description>Email or Azure AD ID of the Teams user</description>
</CustomField>
FLDEOF

# Create sfdx-project.json for the temp project
cat > "$DEPLOY_DIR/sfdx-project.json" << 'PROJEOF'
{
    "packageDirectories": [
        {
            "path": "force-app",
            "default": true
        }
    ],
    "name": "teams-webhook",
    "namespace": "",
    "sfdcLoginUrl": "https://login.salesforce.com",
    "sourceApiVersion": "62.0"
}
PROJEOF

echo -e "${GREEN}Package prepared at: $DEPLOY_DIR${NC}"
echo ""

# ─── Step 3: Deploy to org ────────────────────────────────────────────────────
echo -e "${YELLOW}Deploying to your Salesforce org...${NC}"
echo ""

sf project deploy start \
    --source-dir "$DEPLOY_DIR/force-app" \
    --wait 10 \
    --verbose \
    $TARGET_FLAG

DEPLOY_STATUS=$?

if [ $DEPLOY_STATUS -eq 0 ]; then
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Deployment successful!                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Create Custom Metadata type: Teams_Config_{ClientName}__mdt"
    echo "     Fields: Microsoft_App_Id__c, Microsoft_App_Password__c, Agent_Id__c"
    echo "  2. Create a Default record with your Azure Bot credentials and Agent ID"
    echo "  3. Set up Named Credentials (Microsoft Bot Framework + Agentforce Agent API)"
    echo "  4. Expose the endpoint via a Salesforce Site (see README)"
    echo "  5. Set the messaging endpoint in Azure Bot config to your Site URL"
    echo ""
else
    echo ""
    echo -e "${RED}Deployment failed. Check the errors above.${NC}"
    echo "Common fixes:"
    echo "  - Make sure you're authenticated: sf org login web"
    echo "  - Check that your org has API version 62.0+ support"
    echo "  - Verify the Apex class compiles (no typos in {ClientName})"
    echo ""
    exit 1
fi

# ─── Step 4: Set up Remote Site Settings ──────────────────────────────────────
echo -e "${YELLOW}Adding Remote Site Settings for Microsoft endpoints...${NC}"

REMOTE_SITES_DIR="$DEPLOY_DIR/force-app/main/default/remoteSiteSettings"
mkdir -p "$REMOTE_SITES_DIR"

cat > "$REMOTE_SITES_DIR/Microsoft_Login.remoteSite-meta.xml" << 'RSEOF'
<?xml version="1.0" encoding="UTF-8"?>
<RemoteSiteSetting xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Microsoft_Login</fullName>
    <isActive>true</isActive>
    <url>https://login.microsoftonline.com</url>
    <description>Microsoft OAuth token endpoint for Bot Framework authentication</description>
</RemoteSiteSetting>
RSEOF

cat > "$REMOTE_SITES_DIR/Microsoft_Bot_Framework.remoteSite-meta.xml" << 'RSEOF'
<?xml version="1.0" encoding="UTF-8"?>
<RemoteSiteSetting xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Microsoft_Bot_Framework</fullName>
    <isActive>true</isActive>
    <url>https://smba.trafficmanager.net</url>
    <description>Bot Framework Connector service URL for sending replies to Teams</description>
</RemoteSiteSetting>
RSEOF

cat > "$REMOTE_SITES_DIR/Bot_Framework_Login.remoteSite-meta.xml" << 'RSEOF'
<?xml version="1.0" encoding="UTF-8"?>
<RemoteSiteSetting xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Bot_Framework_Login</fullName>
    <isActive>true</isActive>
    <url>https://login.botframework.com</url>
    <description>Bot Framework OpenID metadata endpoint for token validation</description>
</RemoteSiteSetting>
RSEOF

sf project deploy start \
    --source-dir "$REMOTE_SITES_DIR" \
    --wait 5 \
    $TARGET_FLAG 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Remote Site Settings deployed.${NC}"
else
    echo -e "${YELLOW}Remote Site Settings deployment skipped (deploy manually if needed).${NC}"
    echo "  Add these URLs in Setup > Remote Site Settings:"
    echo "    - https://login.microsoftonline.com"
    echo "    - https://smba.trafficmanager.net"
    echo "    - https://login.botframework.com"
fi

echo ""

# ─── Cleanup ──────────────────────────────────────────────────────────────────
rm -rf "$DEPLOY_DIR"

echo "Done. See README.md for full setup instructions."
