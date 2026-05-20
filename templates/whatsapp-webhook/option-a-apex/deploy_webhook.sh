#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# deploy_webhook.sh
#
# Deploys the WhatsApp webhook handler to your Salesforce org.
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
#   ./deploy_webhook.sh
# ──────────────────────────────────────────────────────────────────────────────

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  WhatsApp Webhook Deployment for {ClientName}        ║"
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
if ! sf org display 2>/dev/null | grep -q "Connected Status"; then
    echo -e "${YELLOW}You may not be authenticated. Attempting deployment anyway...${NC}"
fi

echo -e "${GREEN}Prerequisites OK${NC}"
echo ""

# ─── Step 2: Create project structure for deployment ──────────────────────────
echo -e "${YELLOW}Preparing deployment package...${NC}"

DEPLOY_DIR=$(mktemp -d)
CLASSES_DIR="$DEPLOY_DIR/force-app/main/default/classes"
OBJECTS_DIR="$DEPLOY_DIR/force-app/main/default/objects/WhatsApp_Session__c"

mkdir -p "$CLASSES_DIR"
mkdir -p "$OBJECTS_DIR/fields"

# Copy Apex class
cp "$(dirname "$0")/WhatsAppWebhook_{ClientName}.cls" "$CLASSES_DIR/"
cp "$(dirname "$0")/WhatsAppWebhook_{ClientName}.cls-meta.xml" "$CLASSES_DIR/"

# Copy custom object (split into individual field files for source format)
# First, create the object definition
cat > "$OBJECTS_DIR/WhatsApp_Session__c.object-meta.xml" << 'OBJEOF'
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">
    <label>WhatsApp Session</label>
    <pluralLabel>WhatsApp Sessions</pluralLabel>
    <nameField>
        <label>Session Name</label>
        <type>AutoNumber</type>
        <displayFormat>WA-{0000000}</displayFormat>
    </nameField>
    <deploymentStatus>Deployed</deploymentStatus>
    <sharingModel>ReadWrite</sharingModel>
    <description>Maps WhatsApp phone numbers to Agentforce Agent API session IDs.</description>
</CustomObject>
OBJEOF

# Create field definitions
cat > "$OBJECTS_DIR/fields/Phone_Number__c.field-meta.xml" << 'FLDEOF'
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Phone_Number__c</fullName>
    <label>Phone Number</label>
    <type>Text</type>
    <length>20</length>
    <required>true</required>
    <unique>true</unique>
    <externalId>true</externalId>
    <description>WhatsApp phone number (with country code, no + prefix)</description>
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

# Create sfdx-project.json for the temp project
cat > "$DEPLOY_DIR/sfdx-project.json" << 'PROJEOF'
{
    "packageDirectories": [
        {
            "path": "force-app",
            "default": true
        }
    ],
    "name": "whatsapp-webhook",
    "namespace": "",
    "sfdcLoginUrl": "https://login.salesforce.com",
    "sourceApiVersion": "61.0"
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
    --verbose

DEPLOY_STATUS=$?

if [ $DEPLOY_STATUS -eq 0 ]; then
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Deployment successful!                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Set up a Salesforce Site to expose the webhook (see README)"
    echo "  2. Create Named Credentials for Meta API and Agent API"
    echo "  3. Create the Custom Metadata record (WhatsApp_Config_{ClientName}__mdt)"
    echo "  4. Configure the webhook URL in Meta's App Dashboard"
    echo ""
else
    echo ""
    echo -e "${RED}Deployment failed. Check the errors above.${NC}"
    echo "Common fixes:"
    echo "  - Make sure you're authenticated: sf org login web"
    echo "  - Check that your org has API version 61.0+ support"
    echo ""
    exit 1
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
rm -rf "$DEPLOY_DIR"
