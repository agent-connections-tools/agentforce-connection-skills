# {ClientName} Instagram Webhook (Apex)

Bridges Meta's Instagram Messaging API to Salesforce Agentforce Agent API — entirely within Salesforce (no external hosting).

## Prerequisites

- Salesforce org with Agentforce agent configured
- Meta App with Instagram Messaging product enabled
- Instagram Professional Account connected to Meta app

## Deployment

```bash
chmod +x deploy_webhook.sh
./deploy_webhook.sh your-org-alias
```

## Post-Deployment Setup

1. **Create a Salesforce Site** — Setup > Sites > New. Add `InstagramWebhook_{ClientName}` as a public Apex REST endpoint.

2. **Create Named Credentials:**
   - `Meta_Instagram_API` → URL: `https://graph.facebook.com`, Auth: Named Principal with your Page Access Token
   - `Agentforce_Agent_API` → URL: your org domain, Auth: Per-User or Named Principal

3. **Create Custom Metadata:**
   - Type: `Instagram_Config_{ClientName}__mdt`
   - Record: `Default`
   - Fields: `Verify_Token__c`, `Agent_Id__c`, `Instagram_Id__c`

4. **Configure Meta Webhook:**
   - Callback URL: `https://your-site.force.com/services/apexrest/instagram/{ClientName}/webhook`
   - Verify Token: matches Custom Metadata
   - Subscribe to: `messages`, `messaging_postbacks`

## Testing

Send a DM to your Instagram Professional Account. The agent responds with carousels, buttons, quick replies, or media based on context.
