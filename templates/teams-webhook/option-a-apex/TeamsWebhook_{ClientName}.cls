/**
 * Microsoft Teams Webhook Handler for {ClientName}
 *
 * This Apex REST class bridges the Microsoft Bot Framework to the Salesforce Agent API.
 * It receives incoming Teams messages (Bot Framework Activity objects), routes them to
 * an Agentforce agent, and sends the agent's rich responses back to Teams as Adaptive Cards.
 *
 * Deployment: Expose via Salesforce Site or Digital Experience (see README).
 * Auth: Uses Named Credentials for both Microsoft Bot Framework and Salesforce Agent API.
 */
@RestResource(urlMapping='/teams/*')
global with sharing class TeamsWebhook_{ClientName} {

    // ─── CONFIGURATION ───────────────────────────────────────────────────────────
    // Named Credential for calling Microsoft Bot Framework Connector API
    private static final String MICROSOFT_NAMED_CREDENTIAL = 'Microsoft_Bot_Framework';
    // Named Credential for calling Salesforce Agent API
    private static final String AGENT_NAMED_CREDENTIAL = 'Agentforce_Agent_API';
    // Microsoft App ID (from Azure Bot registration)
    private static final String MICROSOFT_APP_ID = Teams_Config_{ClientName}__mdt.getInstance('Default').Microsoft_App_Id__c;
    // The Agentforce agent/bot ID to route messages to
    private static final String AGENT_ID = Teams_Config_{ClientName}__mdt.getInstance('Default').Agent_Id__c;
    // Surface ID for the custom connection
    private static final String SURFACE_ID = '{surfaceId}';
    // Microsoft OpenID metadata URL for token validation
    private static final String OPENID_METADATA_URL = 'https://login.botframework.com/v1/.well-known/openidconfiguration';
    // Microsoft token endpoint for Bot Framework Connector auth
    private static final String MS_TOKEN_ENDPOINT = 'https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token';

    // ─── POST: INCOMING TEAMS MESSAGES ───────────────────────────────────────────
    // The Bot Framework sends a POST with an Activity object whenever someone
    // sends a message to your bot in Teams. We acknowledge quickly with 200,
    // then process asynchronously.
    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        String body = req.requestBody.toString();

        // Validate the inbound JWT token from Microsoft
        String authHeader = req.headers.get('Authorization');
        if (!validateBotFrameworkToken(authHeader)) {
            res.statusCode = 401;
            res.responseBody = Blob.valueOf('Unauthorized');
            return;
        }

        // Always return 200 quickly to Bot Framework (they retry on non-2xx)
        res.statusCode = 200;
        res.responseBody = Blob.valueOf('OK');

        // Parse the incoming Bot Framework Activity object
        Map<String, Object> activity = (Map<String, Object>) JSON.deserializeUntyped(body);

        // Only process message activities
        String activityType = (String) activity.get('type');
        if (activityType != 'message') {
            return;
        }

        // Extract message details from the Activity
        ActivityInfo actInfo = extractActivity(activity);
        if (actInfo == null || String.isBlank(actInfo.text)) {
            return;
        }

        // Process asynchronously so we don't hold up the 200 response
        System.enqueueJob(new TeamsMessageProcessor(actInfo));
    }

    // ─── TOKEN VALIDATION ────────────────────────────────────────────────────────
    // Validates the JWT Bearer token sent by Bot Framework.
    // In production, this should verify the token signature against Microsoft's
    // OpenID signing keys. For this implementation, we validate the token structure
    // and claims (issuer, audience) without full cryptographic verification
    // (Salesforce Apex lacks native JWT signature verification libraries).
    //
    // For full security, consider using a middleware (e.g., Azure Function) that
    // validates the signature and forwards to Salesforce, or implement via
    // Salesforce Shield Event Monitoring for anomaly detection.
    private static Boolean validateBotFrameworkToken(String authHeader) {
        if (String.isBlank(authHeader) || !authHeader.startsWith('Bearer ')) {
            return false;
        }

        String token = authHeader.substring(7);

        try {
            // Decode the JWT payload (middle segment)
            List<String> parts = token.split('\\.');
            if (parts.size() != 3) {
                return false;
            }

            // Decode the payload (base64url)
            String payload = parts[1];
            // Add padding if needed for base64 decoding
            Integer padLength = Math.mod(4 - Math.mod(payload.length(), 4), 4);
            payload += '='.repeat(padLength);
            payload = payload.replace('-', '+').replace('_', '/');

            String decodedPayload = EncodingUtil.base64Decode(payload).toString();
            Map<String, Object> claims = (Map<String, Object>) JSON.deserializeUntyped(decodedPayload);

            // Validate issuer — must be from Bot Framework or Microsoft STS
            String issuer = (String) claims.get('iss');
            if (issuer == null || (!issuer.contains('api.botframework.com') &&
                !issuer.contains('sts.windows.net'))) {
                System.debug(LoggingLevel.WARN, 'Invalid token issuer: ' + issuer);
                return false;
            }

            // Validate audience — must be our Microsoft App ID
            String audience = (String) claims.get('aud');
            if (audience != MICROSOFT_APP_ID) {
                System.debug(LoggingLevel.WARN, 'Invalid token audience: ' + audience);
                return false;
            }

            // Validate expiration
            Object expObj = claims.get('exp');
            if (expObj != null) {
                Long expTimestamp;
                if (expObj instanceof Integer) {
                    expTimestamp = (Integer) expObj;
                } else {
                    expTimestamp = (Long) expObj;
                }
                Long nowTimestamp = DateTime.now().getTime() / 1000;
                if (nowTimestamp > expTimestamp) {
                    System.debug(LoggingLevel.WARN, 'Token expired');
                    return false;
                }
            }

            return true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Token validation error: ' + e.getMessage());
            return false;
        }
    }

    // ─── ACTIVITY EXTRACTION ─────────────────────────────────────────────────────
    // Bot Framework Activity objects are flat (unlike Meta's deeply nested structure).
    // We extract the fields we need for processing and reply.
    private static ActivityInfo extractActivity(Map<String, Object> activity) {
        try {
            String text = (String) activity.get('text');
            String conversationId = '';
            String activityId = (String) activity.get('id');
            String serviceUrl = (String) activity.get('serviceUrl');

            // Extract conversation ID
            Map<String, Object> conversation = (Map<String, Object>) activity.get('conversation');
            if (conversation != null) {
                conversationId = (String) conversation.get('id');
            }

            // Extract user info
            String userName = '';
            String userEmail = '';
            Map<String, Object> from = (Map<String, Object>) activity.get('from');
            if (from != null) {
                userName = (String) from.get('name');
                // Azure AD user ID — email may be in channelData or from aadObjectId
                userEmail = (String) from.get('id');
            }

            // Strip the bot @mention from the message text (Teams prepends it)
            if (String.isNotBlank(text)) {
                // Remove <at>BotName</at> tags that Teams adds when @mentioning the bot
                text = text.replaceAll('<at>[^<]*</at>', '').trim();
            }

            if (String.isBlank(text) || String.isBlank(conversationId)) {
                return null;
            }

            ActivityInfo info = new ActivityInfo();
            info.text = text;
            info.conversationId = conversationId;
            info.activityId = activityId;
            info.serviceUrl = serviceUrl;
            info.userName = userName;
            info.userEmail = userEmail;
            return info;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to extract activity: ' + e.getMessage());
            return null;
        }
    }

    // ─── DATA CLASSES ────────────────────────────────────────────────────────────

    global class ActivityInfo {
        public String text;
        public String conversationId;
        public String activityId;
        public String serviceUrl;
        public String userName;
        public String userEmail;
    }

    // ─── ASYNC PROCESSOR (Queueable) ────────────────────────────────────────────
    // Handles the actual Agent API call and Teams reply outside of the webhook response.
    global class TeamsMessageProcessor implements Queueable, Database.AllowsCallouts {
        private ActivityInfo actInfo;

        public TeamsMessageProcessor(ActivityInfo actInfo) {
            this.actInfo = actInfo;
        }

        public void execute(QueueableContext ctx) {
            try {
                // Step 1: Get or create session for this conversation
                SessionInfo session = getOrCreateSession(actInfo.conversationId, actInfo.userName, actInfo.userEmail);

                // Step 2: Send message to Agent API
                String agentResponse = callAgentAPI(session, actInfo.text);

                // Step 3: Parse agent response and translate to Teams Adaptive Card format
                Map<String, Object> teamsReply = convertToTeamsFormat(agentResponse);

                // Step 4: Send reply back to Teams via Bot Framework Connector
                sendToTeams(actInfo.serviceUrl, actInfo.conversationId, actInfo.activityId, teamsReply);

                // Step 5: Update session last activity
                updateSessionActivity(session.recordId);

            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Teams processing error: ' + e.getMessage());
                // Send a friendly error message back to the user
                Map<String, Object> errorReply = new Map<String, Object>{
                    'type' => 'message',
                    'text' => 'I\'m having trouble right now. Please try again in a moment.'
                };
                sendToTeams(actInfo.serviceUrl, actInfo.conversationId, actInfo.activityId, errorReply);
            }
        }

        // ─── SESSION MANAGEMENT ──────────────────────────────────────────────────
        // Maps Teams conversation IDs to Agent API sessions.
        // Sessions are stored in the Teams_Session__c custom object.
        private SessionInfo getOrCreateSession(String conversationId, String userName, String userEmail) {
            // Look for an existing active session (active within last 30 minutes)
            DateTime cutoff = DateTime.now().addMinutes(-30);
            List<Teams_Session__c> sessions = [
                SELECT Id, Agent_Session_Id__c, Last_Sequence_Id__c
                FROM Teams_Session__c
                WHERE Conversation_Id__c = :conversationId
                AND Last_Activity__c > :cutoff
                LIMIT 1
            ];

            if (!sessions.isEmpty()) {
                SessionInfo info = new SessionInfo();
                info.recordId = sessions[0].Id;
                info.agentSessionId = sessions[0].Agent_Session_Id__c;
                info.sequenceId = (Integer) sessions[0].Last_Sequence_Id__c;
                info.isNew = false;
                return info;
            }

            // Create a new Agent API session
            String newSessionId = createAgentSession();

            // Upsert session record (keyed on conversation ID)
            Teams_Session__c sessionRecord = new Teams_Session__c(
                Conversation_Id__c = conversationId,
                Agent_Session_Id__c = newSessionId,
                Last_Sequence_Id__c = 1,
                Last_Activity__c = DateTime.now(),
                User_Name__c = userName,
                User_Email__c = userEmail
            );
            upsert sessionRecord Conversation_Id__c;

            SessionInfo info = new SessionInfo();
            info.recordId = sessionRecord.Id;
            info.agentSessionId = newSessionId;
            info.sequenceId = 1;
            info.isNew = true;
            return info;
        }

        // Creates a new session with the Agent API
        private String createAgentSession() {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + AGENT_NAMED_CREDENTIAL + '/einstein/ai-agent/v1/sessions');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');

            Map<String, Object> body = new Map<String, Object>{
                'externalSessionKey' => generateSessionKey(),
                'instanceConfig' => new Map<String, Object>{
                    'endpoint' => URL.getOrgDomainURL().toExternalForm()
                },
                'streamingCapabilities' => new Map<String, Object>{
                    'chunkTypes' => new List<String>{ 'Text' }
                },
                'bypassUser' => false
            };
            req.setBody(JSON.serialize(body));

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
                throw new CalloutException('Failed to create agent session: ' + res.getBody());
            }

            Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return (String) responseMap.get('sessionId');
        }

        // Generates a unique session key
        private String generateSessionKey() {
            return 'teams-' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 16);
        }

        // ─── AGENT API CALL ──────────────────────────────────────────────────────
        // Sends the user's message to the Agentforce Agent API and gets the response.
        private String callAgentAPI(SessionInfo session, String userMessage) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + AGENT_NAMED_CREDENTIAL +
                '/einstein/ai-agent/v1/sessions/' + session.agentSessionId + '/messages');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');

            Integer nextSequenceId = session.sequenceId + 1;

            Map<String, Object> body = new Map<String, Object>{
                'message' => new Map<String, Object>{
                    'sequenceId' => nextSequenceId,
                    'type' => 'Text',
                    'text' => userMessage
                },
                'variables' => new List<Object>(),
                'surfaceType' => 'Custom',
                'surfaceId' => SURFACE_ID
            };
            req.setBody(JSON.serialize(body));
            req.setTimeout(120000); // 2 minute timeout for agent processing

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200) {
                throw new CalloutException('Agent API error (' + res.getStatusCode() + '): ' + res.getBody());
            }

            // Update the sequence ID
            Teams_Session__c sessionUpdate = new Teams_Session__c(
                Id = session.recordId,
                Last_Sequence_Id__c = nextSequenceId
            );
            update sessionUpdate;

            return res.getBody();
        }

        // ─── RESPONSE FORMAT TRANSLATION ─────────────────────────────────────────
        // This is the core translation function. It takes the Agent API's structured
        // JSON response and converts it into Bot Framework Activity with Adaptive Cards.
        //
        // Supported mappings:
        //   TeamsButtons    -> Adaptive Card with Action.Submit buttons
        //   TeamsChoiceSet  -> Adaptive Card with Input.ChoiceSet dropdown
        //   TeamsHeroCard   -> Hero Card attachment
        //   TeamsCarousel   -> Multiple card attachments (carousel)
        //   Plain text      -> Simple text message
        private Map<String, Object> convertToTeamsFormat(String agentResponseBody) {
            Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(agentResponseBody);

            // The Agent API returns messages in a 'messages' array
            List<Object> agentMessages = (List<Object>) responseMap.get('messages');
            if (agentMessages == null || agentMessages.isEmpty()) {
                return buildTextReply('I processed your request but have nothing to display.');
            }

            // Collect all attachments and text from agent messages
            List<Object> allAttachments = new List<Object>();
            String plainText = '';

            for (Object msgObj : agentMessages) {
                Map<String, Object> msg = (Map<String, Object>) msgObj;
                String msgType = (String) msg.get('type');

                if (msgType == 'Text') {
                    String text = (String) msg.get('text');
                    Map<String, Object> structured = tryParseStructuredResponse(text);

                    if (structured != null) {
                        allAttachments.addAll(translateStructuredResponse(structured));
                    } else {
                        // Accumulate plain text
                        if (String.isNotBlank(plainText)) {
                            plainText += '\n\n';
                        }
                        plainText += text;
                    }
                } else if (msgType == 'RichContent') {
                    Map<String, Object> content = (Map<String, Object>) msg.get('content');
                    if (content != null) {
                        allAttachments.addAll(translateStructuredResponse(content));
                    }
                }
            }

            // Build the final reply
            if (!allAttachments.isEmpty()) {
                Map<String, Object> reply = new Map<String, Object>{
                    'type' => 'message',
                    'attachments' => allAttachments
                };
                if (String.isNotBlank(plainText)) {
                    reply.put('text', plainText);
                }
                return reply;
            }

            if (String.isNotBlank(plainText)) {
                return buildTextReply(plainText);
            }

            return buildTextReply('I processed your request but have nothing to display.');
        }

        // Attempts to parse text as a structured response format JSON
        private Map<String, Object> tryParseStructuredResponse(String text) {
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(text);
                if (parsed.containsKey('type') || parsed.containsKey('responseFormatType')) {
                    return parsed;
                }
            } catch (Exception e) {
                // Not JSON — that's fine, it's plain text
            }
            return null;
        }

        // Translates a structured response format object into Teams attachment(s)
        private List<Object> translateStructuredResponse(Map<String, Object> structured) {
            List<Object> attachments = new List<Object>();

            String responseType = (String) structured.get('type');
            if (responseType == null) {
                responseType = (String) structured.get('responseFormatType');
            }

            if (responseType == 'TeamsButtons') {
                attachments.add(buildButtonCard(structured));
            } else if (responseType == 'TeamsChoiceSet') {
                attachments.add(buildChoiceSetCard(structured));
            } else if (responseType == 'TeamsHeroCard') {
                attachments.add(buildHeroCard(structured));
            } else if (responseType == 'TeamsCarousel') {
                attachments.addAll(buildCarouselCards(structured));
            } else {
                // Unknown format — extract any text content and send as Adaptive Card
                String bodyText = (String) structured.get('body');
                if (bodyText == null) bodyText = (String) structured.get('text');
                if (bodyText == null) bodyText = JSON.serialize(structured);
                attachments.add(buildSimpleAdaptiveCard(bodyText));
            }

            return attachments;
        }

        // Builds a simple text reply (no attachments)
        private Map<String, Object> buildTextReply(String text) {
            return new Map<String, Object>{
                'type' => 'message',
                'text' => text
            };
        }

        // Builds an Adaptive Card with Action.Submit buttons
        private Map<String, Object> buildButtonCard(Map<String, Object> data) {
            String bodyText = (String) data.get('body');
            String headerText = (String) data.get('header');
            List<Object> buttons = (List<Object>) data.get('buttons');

            // Build card body elements
            List<Object> cardBody = new List<Object>();

            if (String.isNotBlank(headerText)) {
                cardBody.add(new Map<String, Object>{
                    'type' => 'TextBlock',
                    'text' => headerText,
                    'weight' => 'Bolder',
                    'size' => 'Medium'
                });
            }

            if (String.isNotBlank(bodyText)) {
                cardBody.add(new Map<String, Object>{
                    'type' => 'TextBlock',
                    'text' => bodyText,
                    'wrap' => true
                });
            }

            // Build actions
            List<Object> actions = new List<Object>();
            if (buttons != null) {
                for (Object btnObj : buttons) {
                    Map<String, Object> btn = (Map<String, Object>) btnObj;
                    actions.add(new Map<String, Object>{
                        'type' => 'Action.Submit',
                        'title' => (String) btn.get('title'),
                        'data' => new Map<String, Object>{
                            'action' => (String) btn.get('id'),
                            'text' => (String) btn.get('id')
                        }
                    });
                }
            }

            Map<String, Object> adaptiveCard = new Map<String, Object>{
                'type' => 'AdaptiveCard',
                '$schema' => 'http://adaptivecards.io/schemas/adaptive-card.json',
                'version' => '1.4',
                'body' => cardBody,
                'actions' => actions
            };

            return new Map<String, Object>{
                'contentType' => 'application/vnd.microsoft.card.adaptive',
                'content' => adaptiveCard
            };
        }

        // Builds an Adaptive Card with Input.ChoiceSet dropdown
        private Map<String, Object> buildChoiceSetCard(Map<String, Object> data) {
            String bodyText = (String) data.get('body');
            String headerText = (String) data.get('header');
            String placeholder = (String) data.get('placeholder');
            List<Object> choices = (List<Object>) data.get('choices');

            // Build card body elements
            List<Object> cardBody = new List<Object>();

            if (String.isNotBlank(headerText)) {
                cardBody.add(new Map<String, Object>{
                    'type' => 'TextBlock',
                    'text' => headerText,
                    'weight' => 'Bolder',
                    'size' => 'Medium'
                });
            }

            if (String.isNotBlank(bodyText)) {
                cardBody.add(new Map<String, Object>{
                    'type' => 'TextBlock',
                    'text' => bodyText,
                    'wrap' => true
                });
            }

            // Build choice set
            List<Object> choiceItems = new List<Object>();
            if (choices != null) {
                for (Object choiceObj : choices) {
                    Map<String, Object> choice = (Map<String, Object>) choiceObj;
                    choiceItems.add(new Map<String, Object>{
                        'title' => (String) choice.get('title'),
                        'value' => (String) choice.get('value')
                    });
                }
            }

            cardBody.add(new Map<String, Object>{
                'type' => 'Input.ChoiceSet',
                'id' => 'userChoice',
                'style' => 'compact',
                'placeholder' => placeholder != null ? placeholder : 'Select an option',
                'choices' => choiceItems
            });

            // Submit action
            List<Object> actions = new List<Object>{
                new Map<String, Object>{
                    'type' => 'Action.Submit',
                    'title' => 'Submit'
                }
            };

            Map<String, Object> adaptiveCard = new Map<String, Object>{
                'type' => 'AdaptiveCard',
                '$schema' => 'http://adaptivecards.io/schemas/adaptive-card.json',
                'version' => '1.4',
                'body' => cardBody,
                'actions' => actions
            };

            return new Map<String, Object>{
                'contentType' => 'application/vnd.microsoft.card.adaptive',
                'content' => adaptiveCard
            };
        }

        // Builds a Hero Card attachment
        private Map<String, Object> buildHeroCard(Map<String, Object> data) {
            String title = (String) data.get('title');
            String subtitle = (String) data.get('subtitle');
            String text = (String) data.get('text');
            String imageUrl = (String) data.get('imageUrl');
            List<Object> buttons = (List<Object>) data.get('buttons');

            Map<String, Object> heroCard = new Map<String, Object>{
                'title' => title != null ? title : '',
                'subtitle' => subtitle != null ? subtitle : ''
            };

            if (String.isNotBlank(text)) {
                heroCard.put('text', text);
            }

            // Add image if provided
            if (String.isNotBlank(imageUrl)) {
                heroCard.put('images', new List<Object>{
                    new Map<String, Object>{ 'url' => imageUrl }
                });
            }

            // Add buttons
            if (buttons != null && !buttons.isEmpty()) {
                List<Object> cardButtons = new List<Object>();
                for (Object btnObj : buttons) {
                    Map<String, Object> btn = (Map<String, Object>) btnObj;
                    String btnType = (String) btn.get('type');
                    cardButtons.add(new Map<String, Object>{
                        'type' => btnType != null ? btnType : 'messageBack',
                        'title' => (String) btn.get('title'),
                        'value' => (String) btn.get('id'),
                        'text' => (String) btn.get('id')
                    });
                }
                heroCard.put('buttons', cardButtons);
            }

            return new Map<String, Object>{
                'contentType' => 'application/vnd.microsoft.teams.card.o365connector',
                'content' => heroCard
            };
        }

        // Builds multiple card attachments for a carousel
        private List<Object> buildCarouselCards(Map<String, Object> data) {
            List<Object> attachments = new List<Object>();
            List<Object> cards = (List<Object>) data.get('cards');

            if (cards != null) {
                for (Object cardObj : cards) {
                    Map<String, Object> card = (Map<String, Object>) cardObj;
                    String title = (String) card.get('title');
                    String subtitle = (String) card.get('subtitle');
                    String text = (String) card.get('description');
                    String imageUrl = (String) card.get('imageUrl');
                    List<Object> buttons = (List<Object>) card.get('buttons');

                    // Build each card as an Adaptive Card
                    List<Object> cardBody = new List<Object>();

                    if (String.isNotBlank(imageUrl)) {
                        cardBody.add(new Map<String, Object>{
                            'type' => 'Image',
                            'url' => imageUrl,
                            'size' => 'Stretch'
                        });
                    }

                    if (String.isNotBlank(title)) {
                        cardBody.add(new Map<String, Object>{
                            'type' => 'TextBlock',
                            'text' => title,
                            'weight' => 'Bolder',
                            'size' => 'Medium'
                        });
                    }

                    if (String.isNotBlank(subtitle)) {
                        cardBody.add(new Map<String, Object>{
                            'type' => 'TextBlock',
                            'text' => subtitle,
                            'isSubtle' => true,
                            'spacing' => 'None'
                        });
                    }

                    if (String.isNotBlank(text)) {
                        cardBody.add(new Map<String, Object>{
                            'type' => 'TextBlock',
                            'text' => text,
                            'wrap' => true
                        });
                    }

                    // Build actions for this card
                    List<Object> actions = new List<Object>();
                    if (buttons != null) {
                        for (Object btnObj : buttons) {
                            Map<String, Object> btn = (Map<String, Object>) btnObj;
                            actions.add(new Map<String, Object>{
                                'type' => 'Action.Submit',
                                'title' => (String) btn.get('title'),
                                'data' => new Map<String, Object>{
                                    'action' => (String) btn.get('id'),
                                    'text' => (String) btn.get('id')
                                }
                            });
                        }
                    }

                    Map<String, Object> adaptiveCard = new Map<String, Object>{
                        'type' => 'AdaptiveCard',
                        '$schema' => 'http://adaptivecards.io/schemas/adaptive-card.json',
                        'version' => '1.4',
                        'body' => cardBody
                    };
                    if (!actions.isEmpty()) {
                        adaptiveCard.put('actions', actions);
                    }

                    attachments.add(new Map<String, Object>{
                        'contentType' => 'application/vnd.microsoft.card.adaptive',
                        'content' => adaptiveCard
                    });
                }
            }

            return attachments;
        }

        // Builds a simple Adaptive Card with just a text block
        private Map<String, Object> buildSimpleAdaptiveCard(String text) {
            Map<String, Object> adaptiveCard = new Map<String, Object>{
                'type' => 'AdaptiveCard',
                '$schema' => 'http://adaptivecards.io/schemas/adaptive-card.json',
                'version' => '1.4',
                'body' => new List<Object>{
                    new Map<String, Object>{
                        'type' => 'TextBlock',
                        'text' => text,
                        'wrap' => true
                    }
                }
            };

            return new Map<String, Object>{
                'contentType' => 'application/vnd.microsoft.card.adaptive',
                'content' => adaptiveCard
            };
        }

        // ─── SEND TO TEAMS ──────────────────────────────────────────────────────
        // Posts a reply back to Teams via the Bot Framework Connector API.
        // Requires a Bot Framework access token (obtained via Microsoft App credentials).
        private void sendToTeams(String serviceUrl, String conversationId, String replyToId, Map<String, Object> replyContent) {
            // Get Bot Framework access token
            String accessToken = getBotFrameworkToken();

            // Build the reply URL
            String replyUrl = serviceUrl;
            if (!replyUrl.endsWith('/')) {
                replyUrl += '/';
            }
            replyUrl += 'v3/conversations/' + EncodingUtil.urlEncode(conversationId, 'UTF-8') +
                '/activities/' + EncodingUtil.urlEncode(replyToId, 'UTF-8');

            HttpRequest req = new HttpRequest();
            req.setEndpoint(replyUrl);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Authorization', 'Bearer ' + accessToken);

            // Ensure the reply has the required Activity fields
            if (!replyContent.containsKey('type')) {
                replyContent.put('type', 'message');
            }
            replyContent.put('replyToId', replyToId);

            req.setBody(JSON.serialize(replyContent));

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
                System.debug(LoggingLevel.ERROR,
                    'Bot Framework reply failed (' + res.getStatusCode() + '): ' + res.getBody());
            }
        }

        // Gets an access token from Microsoft for the Bot Framework Connector API.
        // Uses the Microsoft App ID and Password (stored in Named Credential).
        private String getBotFrameworkToken() {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(MS_TOKEN_ENDPOINT);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');

            // Get credentials from Named Credential via a callout
            // The Named Credential stores the App ID and Password
            String tokenBody = 'grant_type=client_credentials' +
                '&client_id=' + EncodingUtil.urlEncode(MICROSOFT_APP_ID, 'UTF-8') +
                '&client_secret=' + EncodingUtil.urlEncode(getMicrosoftAppPassword(), 'UTF-8') +
                '&scope=' + EncodingUtil.urlEncode('https://api.botframework.com/.default', 'UTF-8');

            req.setBody(tokenBody);

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200) {
                throw new CalloutException('Failed to get Bot Framework token: ' + res.getBody());
            }

            Map<String, Object> tokenResponse = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return (String) tokenResponse.get('access_token');
        }

        // Retrieves the Microsoft App Password from Custom Metadata
        // (stored securely — not hardcoded in source)
        private String getMicrosoftAppPassword() {
            return Teams_Config_{ClientName}__mdt.getInstance('Default').Microsoft_App_Password__c;
        }

        // Updates the last activity timestamp on the session record
        private void updateSessionActivity(Id recordId) {
            Teams_Session__c sessionUpdate = new Teams_Session__c(
                Id = recordId,
                Last_Activity__c = DateTime.now()
            );
            update sessionUpdate;
        }
    }

    // Session info wrapper
    private class SessionInfo {
        public Id recordId;
        public String agentSessionId;
        public Integer sequenceId;
        public Boolean isNew;
    }
}
