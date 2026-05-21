#!/bin/bash
# Deploy {ClientName} Portal (Node.js + React) to Heroku
#
# Prerequisites:
#   - Heroku CLI installed and logged in (heroku login)
#   - Git initialized in this directory
#
# Usage: ./deploy_heroku.sh <app-name>
# Example: ./deploy_heroku.sh acme-portal-proxy

set -e

APP_NAME=${1:?"Usage: ./deploy_heroku.sh <app-name>"}

echo "=== Deploying {ClientName} Portal Proxy to Heroku ==="
echo ""

# Check if app exists, create if not
if ! heroku apps:info "$APP_NAME" > /dev/null 2>&1; then
    echo "Creating Heroku app: $APP_NAME"
    heroku create "$APP_NAME"
else
    echo "Using existing Heroku app: $APP_NAME"
fi

echo ""
echo "=== Setting environment variables ==="
echo ""
echo "Set these via Heroku dashboard or CLI:"
echo ""
echo "  heroku config:set SF_LOGIN_URL=https://yourorg.my.salesforce.com --app $APP_NAME"
echo "  heroku config:set SF_CLIENT_ID=your_eca_consumer_key --app $APP_NAME"
echo "  heroku config:set SF_CLIENT_SECRET=your_eca_consumer_secret --app $APP_NAME"
echo "  heroku config:set SF_AGENT_ID=0XxXXXXXXXXXXXX --app $APP_NAME"
echo "  heroku config:set AUTH_JWKS_URI=https://your-idp/.well-known/jwks.json --app $APP_NAME"
echo "  heroku config:set AUTH_ISSUER=https://your-idp/ --app $APP_NAME"
echo "  heroku config:set AUTH_AUDIENCE=your-api-identifier --app $APP_NAME"
echo "  heroku config:set ALLOWED_ORIGIN=https://your-portal-domain.com --app $APP_NAME"
echo ""

# Build client
echo "=== Building React client ==="
cd client && npm install && npm run build && cd ..

# Copy client build to server/public
mkdir -p server/public
cp -r client/dist/* server/public/

# Deploy server
echo "=== Deploying server ==="
cd server
git init 2>/dev/null || true
git add -A
git commit -m "Deploy" --allow-empty
heroku git:remote -a "$APP_NAME"
git push heroku main --force
cd ..

echo ""
echo "=== Done! ==="
echo ""
echo "Your portal proxy is live at: https://$APP_NAME.herokuapp.com"
echo ""
echo "Next steps:"
echo "  1. Set environment variables (see above)"
echo "  2. Configure your IdP to allow callbacks from https://$APP_NAME.herokuapp.com"
echo "  3. Update ALLOWED_ORIGIN to your production portal domain"
echo "  4. Test: visit https://$APP_NAME.herokuapp.com and send a message"
