#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# deploy_heroku.sh
#
# One-command deploy of the Teams webhook to Heroku.
# Also works with Railway (see comments at bottom).
#
# Prerequisites:
#   1. Heroku CLI installed (https://devcenter.heroku.com/articles/heroku-cli)
#   2. Logged into Heroku (run: heroku login)
#   3. Your .env file filled out (we'll set the vars on Heroku)
#
# Usage:
#   chmod +x deploy_heroku.sh
#   ./deploy_heroku.sh
# ──────────────────────────────────────────────────────────────────────────────

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

APP_NAME="teams-webhook-{ClientName}"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Deploy {ClientName} Teams Webhook to Heroku          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Check prerequisites ─────────────────────────────────────────────
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v heroku &> /dev/null; then
    echo -e "${RED}Error: Heroku CLI is not installed.${NC}"
    echo "Install it from: https://devcenter.heroku.com/articles/heroku-cli"
    exit 1
fi

if ! command -v git &> /dev/null; then
    echo -e "${RED}Error: Git is not installed.${NC}"
    exit 1
fi

# Check if logged in
if ! heroku auth:whoami &> /dev/null; then
    echo -e "${YELLOW}Not logged into Heroku. Opening login...${NC}"
    heroku login
fi

echo -e "${GREEN}Prerequisites OK${NC}"
echo ""

# ─── Step 2: Initialize git if needed ────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -d ".git" ]; then
    echo -e "${YELLOW}Initializing git repository...${NC}"
    git init
    echo "node_modules/" > .gitignore
    echo ".env" >> .gitignore
    git add -A
    git commit -m "Initial commit: Teams webhook for {ClientName}"
fi

# ─── Step 3: Create Heroku app ───────────────────────────────────────────────
echo -e "${YELLOW}Creating Heroku app...${NC}"

# Check if app already exists
if heroku apps:info "$APP_NAME" &> /dev/null; then
    echo -e "${GREEN}App '$APP_NAME' already exists. Using it.${NC}"
else
    heroku create "$APP_NAME"
    echo -e "${GREEN}App created: $APP_NAME${NC}"
fi

# ─── Step 4: Set environment variables ───────────────────────────────────────
echo ""
echo -e "${YELLOW}Setting environment variables from .env file...${NC}"

if [ -f ".env" ]; then
    # Read .env file and set each variable on Heroku
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        # Skip lines without a value
        [[ -z "$value" ]] && continue
        # Remove any surrounding quotes from value
        value=$(echo "$value" | sed 's/^["'\'']*//;s/["'\'']*$//')
        heroku config:set "$key=$value" --app "$APP_NAME" > /dev/null
        echo "  Set: $key"
    done < .env
    echo -e "${GREEN}Environment variables set.${NC}"
else
    echo -e "${RED}Warning: No .env file found.${NC}"
    echo "You'll need to set environment variables manually:"
    echo "  heroku config:set MICROSOFT_APP_ID=your-id --app $APP_NAME"
    echo "  heroku config:set MICROSOFT_APP_PASSWORD=your-password --app $APP_NAME"
    echo "  (etc.)"
    echo ""
fi

# ─── Step 5: Deploy ──────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Deploying to Heroku...${NC}"

# Make sure heroku remote exists
if ! git remote | grep -q heroku; then
    heroku git:remote --app "$APP_NAME"
fi

git add -A
git diff-index --quiet HEAD || git commit -m "Deploy update"
git push heroku main 2>/dev/null || git push heroku master

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Deployment successful!                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

MESSAGING_ENDPOINT="https://$APP_NAME.herokuapp.com/api/messages"
echo "Your messaging endpoint:"
echo -e "  ${GREEN}$MESSAGING_ENDPOINT${NC}"
echo ""
echo "Next steps:"
echo "  1. Go to Azure Portal > Bot Services > your bot > Configuration"
echo "  2. Set Messaging Endpoint to: $MESSAGING_ENDPOINT"
echo "  3. Save the configuration"
echo "  4. Go to Teams and message your bot to test!"
echo ""
echo "Useful commands:"
echo "  heroku logs --tail --app $APP_NAME    (watch live logs)"
echo "  heroku config --app $APP_NAME         (view env vars)"
echo "  heroku restart --app $APP_NAME        (restart if stuck)"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# RAILWAY ALTERNATIVE
#
# If you prefer Railway instead of Heroku:
#   1. Install Railway CLI: npm install -g @railway/cli
#   2. Login: railway login
#   3. Create project: railway init
#   4. Set env vars: railway variables set KEY=VALUE (for each .env variable)
#   5. Deploy: railway up
#
# Railway auto-detects the Procfile and Node.js runtime.
# ──────────────────────────────────────────────────────────────────────────────
