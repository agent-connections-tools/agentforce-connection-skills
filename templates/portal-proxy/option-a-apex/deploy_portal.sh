#!/bin/bash
# Deploy {ClientName} Portal (Apex + LWC) to Salesforce
#
# Prerequisites:
#   - Salesforce CLI installed and authenticated (sf org login)
#   - Named Credential "AgentAPI_{ClientName}" configured in the org
#   - Platform Cache partition available (org partition)
#
# Usage: ./deploy_portal.sh <org-alias>
# Example: ./deploy_portal.sh my-sandbox

set -e

ORG=${1:?"Usage: ./deploy_portal.sh <org-alias>"}

echo "=== Deploying {ClientName} Portal (Apex + LWC) ==="
echo ""

# Validate before deploying
echo "=== Validating metadata ==="
sf project deploy start --source-dir . --target-org "$ORG" --dry-run --wait 5

echo ""
echo "=== Validation passed. Deploying... ==="
sf project deploy start --source-dir . --target-org "$ORG" --wait 10

echo ""
echo "=== Done! ==="
echo ""
echo "Next steps:"
echo ""
echo "  1. Configure Named Credential:"
echo "     Setup > Named Credentials > New"
echo "     - Label: AgentAPI_{ClientName}"
echo "     - URL: https://yourorg.my.salesforce.com"
echo "     - Identity Type: Named Principal"
echo "     - Authentication Protocol: OAuth 2.0"
echo "     - Auth Provider: (create one using your ECA consumer key/secret)"
echo ""
echo "  2. Configure Platform Cache:"
echo "     Setup > Platform Cache > Create or select an org partition"
echo "     Allocate at least 1MB to the org partition"
echo ""
echo "  3. Add LWC to Experience Cloud page:"
echo "     Experience Builder > drag '{Client Display Name} Chat' component onto a page"
echo ""
echo "  4. Test:"
echo "     Open the Experience Cloud site and send a message"
echo ""
echo "  Troubleshooting:"
echo "     - 'Cache not available' → Allocate Platform Cache"
echo "     - 'Unauthorized' → Check Named Credential auth configuration"
echo "     - 'Continuation timeout' → Agent response >120s, check agent complexity"
