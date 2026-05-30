#!/bin/bash
# Deploy {ClientName} Instagram Webhook (Apex) to Salesforce
#
# Prerequisites:
#   - Salesforce CLI (sf) installed and authenticated
#   - Target org alias set
#
# Usage:
#   chmod +x deploy_webhook.sh
#   ./deploy_webhook.sh <org-alias>

set -e

ORG_ALIAS="${1:-}"

if [ -z "$ORG_ALIAS" ]; then
    echo "Usage: ./deploy_webhook.sh <org-alias>"
    exit 1
fi

echo "=== Deploying {ClientName} Instagram Webhook to $ORG_ALIAS ==="
echo ""

# Deploy the custom object, Apex class, and site config
sf project deploy start \
    --metadata-dir . \
    --target-org "$ORG_ALIAS"

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Next steps:"
echo "1. Create a Salesforce Site (Setup > Sites) and add InstagramWebhook_{ClientName} as a public endpoint"
echo "2. Create Named Credentials:"
echo "   - 'Meta_Instagram_API' pointing to https://graph.facebook.com"
echo "   - 'Agentforce_Agent_API' pointing to your org's domain"
echo "3. Create Custom Metadata record: Instagram_Config_{ClientName}__mdt.Default with:"
echo "   - Verify_Token__c = your chosen verify token"
echo "   - Agent_Id__c = your Agentforce agent ID"
echo "   - Instagram_Id__c = your Instagram Professional Account ID"
echo "4. In Meta App Dashboard > Instagram > Webhooks:"
echo "   - Set Callback URL to your Site's URL + /services/apexrest/instagram/{ClientName}/webhook"
echo "   - Set Verify Token to match your Custom Metadata value"
echo "   - Subscribe to 'messages' and 'messaging_postbacks'"
echo "5. Send a DM to your Instagram account to test"
