#!/bin/bash
# Deploy {ClientName} Instagram Webhook to Heroku
#
# Prerequisites:
#   - Heroku CLI installed and logged in (heroku login)
#   - A Heroku app created (heroku create)
#
# Usage:
#   chmod +x deploy_heroku.sh
#   ./deploy_heroku.sh

set -e

echo "=== Deploying {ClientName} Instagram Webhook to Heroku ==="
echo ""

# Check if we're in a git repo
if [ ! -d .git ]; then
    git init
    git add .
    git commit -m "Initial commit: {ClientName} Instagram webhook"
fi

# Check if Heroku remote exists
if ! git remote | grep -q heroku; then
    echo "No Heroku remote found. Creating a new Heroku app..."
    heroku create
fi

echo ""
echo "Setting environment variables..."
echo "(You'll be prompted for each value)"
echo ""

read -p "META_VERIFY_TOKEN: " META_VERIFY_TOKEN
read -p "META_PAGE_ACCESS_TOKEN: " META_PAGE_ACCESS_TOKEN
read -p "META_APP_SECRET: " META_APP_SECRET
read -p "META_INSTAGRAM_ID: " META_INSTAGRAM_ID
read -p "SF_CLIENT_ID: " SF_CLIENT_ID
read -p "SF_CLIENT_SECRET: " SF_CLIENT_SECRET
read -p "SF_AGENT_ID: " SF_AGENT_ID
read -p "SF_LOGIN_URL (press enter for https://login.salesforce.com): " SF_LOGIN_URL
SF_LOGIN_URL=${SF_LOGIN_URL:-https://login.salesforce.com}

heroku config:set \
    META_VERIFY_TOKEN="$META_VERIFY_TOKEN" \
    META_PAGE_ACCESS_TOKEN="$META_PAGE_ACCESS_TOKEN" \
    META_APP_SECRET="$META_APP_SECRET" \
    META_INSTAGRAM_ID="$META_INSTAGRAM_ID" \
    SF_CLIENT_ID="$SF_CLIENT_ID" \
    SF_CLIENT_SECRET="$SF_CLIENT_SECRET" \
    SF_AGENT_ID="$SF_AGENT_ID" \
    SF_LOGIN_URL="$SF_LOGIN_URL"

echo ""
echo "Deploying to Heroku..."
git add .
git commit -m "Deploy {ClientName} Instagram webhook" --allow-empty
git push heroku main

echo ""
echo "=== Deployment Complete ==="
HEROKU_URL=$(heroku info -s | grep web_url | cut -d= -f2)
echo "Webhook URL: ${HEROKU_URL}webhook"
echo ""
echo "Next steps:"
echo "1. Go to Meta App Dashboard > Instagram > Messaging > Webhooks"
echo "2. Set Callback URL to: ${HEROKU_URL}webhook"
echo "3. Set Verify Token to: $META_VERIFY_TOKEN"
echo "4. Subscribe to 'messages' and 'messaging_postbacks' fields"
echo "5. Send a DM to your Instagram Professional Account to test"
