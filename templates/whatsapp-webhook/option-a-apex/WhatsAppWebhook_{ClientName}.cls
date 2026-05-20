/**
 * WhatsApp Webhook Handler for {ClientName}
 *
 * This Apex REST class bridges Meta's WhatsApp Cloud API to the Salesforce Agent API.
 * It receives incoming WhatsApp messages, routes them to an Agentforce agent,
 * and sends the agent's rich responses back to WhatsApp.
 *
 * Deployment: Expose via Salesforce Site or Digital Experience (see README).
 * Auth: Uses Named Credentials for both Meta API and Salesforce Agent API.
 */
@RestResource(urlMapping='/whatsapp/{ClientName}/webhook')
global with sharing class WhatsAppWebhook_{ClientName} {

    // ─── CONFIGURATION ───────────────────────────────────────────────────────────
    // Named Credential for calling Meta's WhatsApp Cloud API
    private static final String META_NAMED_CREDENTIAL = 'Meta_WhatsApp_API';
    // Named Credential for calling Salesforce Agent API
    private static final String AGENT_NAMED_CREDENTIAL = 'Agentforce_Agent_API';
    // The verification token you set in Meta's webhook config (store in Custom Metadata)
    private static final String VERIFY_TOKEN = WhatsApp_Config_{ClientName}__mdt.getInstance('Default').Verify_Token__c;
    // The Agentforce agent/bot ID to route messages to
    private static final String AGENT_ID = WhatsApp_Config_{ClientName}__mdt.getInstance('Default').Agent_Id__c;
    // Surface ID for the custom connection
    private static final String SURFACE_ID = '{surfaceId}';
    // Meta Phone Number ID (your business phone on Meta)
    private static final String META_PHONE_NUMBER_ID = WhatsApp_Config_{ClientName}__mdt.getInstance('Default').Phone_Number_Id__c;

    // ─── GET: META VERIFICATION CHALLENGE ────────────────────────────────────────
    // Meta sends a GET request to verify your webhook URL during setup.
    // It includes hub.mode, hub.verify_token, and hub.challenge as query params.
    // You must return the challenge value if the token matches.
    @HttpGet
    global static void doGet() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        String mode = req.params.get('hub.mode');
        String token = req.params.get('hub.verify_token');
        String challenge = req.params.get('hub.challenge');

        // Verify the token matches what we configured
        if (mode == 'subscribe' && token == VERIFY_TOKEN) {
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(challenge);
        } else {
            res.statusCode = 403;
            res.responseBody = Blob.valueOf('Verification failed');
        }
    }

    // ─── POST: INCOMING WHATSAPP MESSAGES ────────────────────────────────────────
    // Meta sends a POST with the message payload whenever someone sends a WhatsApp message.
    // We acknowledge quickly with 200, then process asynchronously.
    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        // Always return 200 quickly to Meta (they retry on non-2xx)
        res.statusCode = 200;
        res.responseBody = Blob.valueOf('OK');

        String body = req.requestBody.toString();

        // Parse the incoming Meta webhook payload
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(body);

        // Extract message details from Meta's nested structure
        MessageInfo msgInfo = extractMessage(payload);

        if (msgInfo == null || String.isBlank(msgInfo.text)) {
            // No actionable message (could be a status update or unsupported type)
            return;
        }

        // Process asynchronously so we don't hold up the 200 response
        System.enqueueJob(new WhatsAppMessageProcessor(msgInfo));
    }

    // ─── MESSAGE EXTRACTION ──────────────────────────────────────────────────────
    // Meta's payload is deeply nested. This method digs into it to find the actual message.
    private static MessageInfo extractMessage(Map<String, Object> payload) {
        try {
            List<Object> entryList = (List<Object>) payload.get('entry');
            if (entryList == null || entryList.isEmpty()) return null;

            Map<String, Object> entry = (Map<String, Object>) entryList[0];
            List<Object> changes = (List<Object>) entry.get('changes');
            if (changes == null || changes.isEmpty()) return null;

            Map<String, Object> change = (Map<String, Object>) changes[0];
            Map<String, Object> value = (Map<String, Object>) change.get('value');

            // Check if this is a message (not a status update)
            List<Object> messages = (List<Object>) value.get('messages');
            if (messages == null || messages.isEmpty()) return null;

            Map<String, Object> message = (Map<String, Object>) messages[0];
            String msgType = (String) message.get('type');
            String from = (String) message.get('from');

            // We handle text messages and interactive replies (button/list selections)
            String text = '';
            if (msgType == 'text') {
                Map<String, Object> textObj = (Map<String, Object>) message.get('text');
                text = (String) textObj.get('body');
            } else if (msgType == 'interactive') {
                // User tapped a button or selected from a list
                Map<String, Object> interactive = (Map<String, Object>) message.get('interactive');
                String interactiveType = (String) interactive.get('type');
                if (interactiveType == 'button_reply') {
                    Map<String, Object> buttonReply = (Map<String, Object>) interactive.get('button_reply');
                    text = (String) buttonReply.get('id');
                } else if (interactiveType == 'list_reply') {
                    Map<String, Object> listReply = (Map<String, Object>) interactive.get('list_reply');
                    text = (String) listReply.get('id');
                }
            } else {
                // Unsupported message type (image, audio, etc.)
                return null;
            }

            MessageInfo info = new MessageInfo();
            info.phoneNumber = from;
            info.text = text;
            return info;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to extract message: ' + e.getMessage());
            return null;
        }
    }

    // ─── DATA CLASSES ────────────────────────────────────────────────────────────

    global class MessageInfo {
        public String phoneNumber;
        public String text;
    }

    // ─── ASYNC PROCESSOR (Queueable) ────────────────────────────────────────────
    // Handles the actual Agent API call and Meta reply outside of the webhook response.
    global class WhatsAppMessageProcessor implements Queueable, Database.AllowsCallouts {
        private MessageInfo msgInfo;

        public WhatsAppMessageProcessor(MessageInfo msgInfo) {
            this.msgInfo = msgInfo;
        }

        public void execute(QueueableContext ctx) {
            try {
                // Step 1: Get or create session for this phone number
                SessionInfo session = getOrCreateSession(msgInfo.phoneNumber);

                // Step 2: Send message to Agent API
                String agentResponse = callAgentAPI(session, msgInfo.text);

                // Step 3: Parse agent response and translate to WhatsApp format
                List<Map<String, Object>> whatsAppMessages = convertToMetaFormat(agentResponse);

                // Step 4: Send each message to WhatsApp via Meta API
                for (Map<String, Object> waMsg : whatsAppMessages) {
                    sendToWhatsApp(msgInfo.phoneNumber, waMsg);
                }

                // Step 5: Update session last activity
                updateSessionActivity(session.recordId);

            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'WhatsApp processing error: ' + e.getMessage());
                // Send a friendly error message to the user
                Map<String, Object> errorMsg = new Map<String, Object>{
                    'type' => 'text',
                    'text' => new Map<String, Object>{
                        'body' => 'I\'m having trouble right now. Please try again in a moment.'
                    }
                };
                sendToWhatsApp(msgInfo.phoneNumber, errorMsg);
            }
        }

        // ─── SESSION MANAGEMENT ──────────────────────────────────────────────────
        // Maps WhatsApp phone numbers to Agent API sessions.
        // Sessions are stored in the WhatsApp_Session__c custom object.
        private SessionInfo getOrCreateSession(String phoneNumber) {
            // Look for an existing active session (active within last 30 minutes)
            DateTime cutoff = DateTime.now().addMinutes(-30);
            List<WhatsApp_Session__c> sessions = [
                SELECT Id, Agent_Session_Id__c, Last_Sequence_Id__c
                FROM WhatsApp_Session__c
                WHERE Phone_Number__c = :phoneNumber
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

            // Upsert session record (keyed on phone number)
            WhatsApp_Session__c sessionRecord = new WhatsApp_Session__c(
                Phone_Number__c = phoneNumber,
                Agent_Session_Id__c = newSessionId,
                Last_Sequence_Id__c = 1,
                Last_Activity__c = DateTime.now()
            );
            upsert sessionRecord Phone_Number__c;

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
            return 'wa-' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 16);
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
            WhatsApp_Session__c sessionUpdate = new WhatsApp_Session__c(
                Id = session.recordId,
                Last_Sequence_Id__c = nextSequenceId
            );
            update sessionUpdate;

            return res.getBody();
        }

        // ─── RESPONSE FORMAT TRANSLATION ─────────────────────────────────────────
        // This is the core translation function. It takes the Agent API's structured
        // JSON response and converts it into Meta's WhatsApp message format.
        //
        // Supported mappings:
        //   WhatsAppButtons → interactive.type: "button"
        //   WhatsAppList    → interactive.type: "list"
        //   WhatsAppMedia   → type: "image" or "video"
        //   WhatsAppCarousel → multiple image messages with caption
        //   Plain text      → type: "text"
        private List<Map<String, Object>> convertToMetaFormat(String agentResponseBody) {
            List<Map<String, Object>> messages = new List<Map<String, Object>>();

            Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(agentResponseBody);

            // The Agent API returns messages in a 'messages' array
            List<Object> agentMessages = (List<Object>) responseMap.get('messages');
            if (agentMessages == null || agentMessages.isEmpty()) {
                return messages;
            }

            for (Object msgObj : agentMessages) {
                Map<String, Object> msg = (Map<String, Object>) msgObj;
                String msgType = (String) msg.get('type');

                if (msgType == 'Text') {
                    // Check if the text contains structured response format JSON
                    String text = (String) msg.get('text');
                    Map<String, Object> structured = tryParseStructuredResponse(text);

                    if (structured != null) {
                        messages.addAll(translateStructuredResponse(structured));
                    } else {
                        // Plain text response — send as regular WhatsApp text
                        messages.add(buildTextMessage(text));
                    }
                } else if (msgType == 'RichContent') {
                    // Rich content from response format
                    Map<String, Object> content = (Map<String, Object>) msg.get('content');
                    if (content != null) {
                        messages.addAll(translateStructuredResponse(content));
                    }
                }
            }

            // If no messages were generated, send a fallback
            if (messages.isEmpty()) {
                messages.add(buildTextMessage('I processed your request but have nothing to display.'));
            }

            return messages;
        }

        // Attempts to parse text as a structured response format JSON
        private Map<String, Object> tryParseStructuredResponse(String text) {
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(text);
                // Check if it has a known response format type
                if (parsed.containsKey('type') || parsed.containsKey('responseFormatType')) {
                    return parsed;
                }
            } catch (Exception e) {
                // Not JSON — that's fine, it's plain text
            }
            return null;
        }

        // Translates a structured response format object into WhatsApp message(s)
        private List<Map<String, Object>> translateStructuredResponse(Map<String, Object> structured) {
            List<Map<String, Object>> messages = new List<Map<String, Object>>();

            String responseType = (String) structured.get('type');
            if (responseType == null) {
                responseType = (String) structured.get('responseFormatType');
            }

            if (responseType == 'WhatsAppButtons') {
                messages.add(buildButtonMessage(structured));
            } else if (responseType == 'WhatsAppList') {
                messages.add(buildListMessage(structured));
            } else if (responseType == 'WhatsAppMedia') {
                messages.add(buildMediaMessage(structured));
            } else if (responseType == 'WhatsAppCarousel') {
                messages.addAll(buildCarouselMessages(structured));
            } else {
                // Unknown format — extract any text content and send as plain text
                String bodyText = (String) structured.get('body');
                if (bodyText == null) bodyText = (String) structured.get('text');
                if (bodyText == null) bodyText = JSON.serialize(structured);
                messages.add(buildTextMessage(bodyText));
            }

            return messages;
        }

        // Builds a simple text message in Meta's format
        private Map<String, Object> buildTextMessage(String text) {
            return new Map<String, Object>{
                'type' => 'text',
                'text' => new Map<String, Object>{
                    'body' => text
                }
            };
        }

        // Builds an interactive button message
        // Meta allows up to 3 buttons per message
        private Map<String, Object> buildButtonMessage(Map<String, Object> data) {
            String bodyText = (String) data.get('body');
            String headerText = (String) data.get('header');
            String footerText = (String) data.get('footer');
            List<Object> buttons = (List<Object>) data.get('buttons');

            List<Object> metaButtons = new List<Object>();
            if (buttons != null) {
                Integer count = 0;
                for (Object btnObj : buttons) {
                    if (count >= 3) break; // Meta limit: max 3 buttons
                    Map<String, Object> btn = (Map<String, Object>) btnObj;
                    metaButtons.add(new Map<String, Object>{
                        'type' => 'reply',
                        'reply' => new Map<String, Object>{
                            'id' => (String) btn.get('id'),
                            'title' => truncate((String) btn.get('title'), 20)
                        }
                    });
                    count++;
                }
            }

            Map<String, Object> interactive = new Map<String, Object>{
                'type' => 'button',
                'body' => new Map<String, Object>{ 'text' => bodyText != null ? bodyText : '' }
            };

            if (String.isNotBlank(headerText)) {
                interactive.put('header', new Map<String, Object>{
                    'type' => 'text',
                    'text' => headerText
                });
            }
            if (String.isNotBlank(footerText)) {
                interactive.put('footer', new Map<String, Object>{ 'text' => footerText });
            }
            interactive.put('action', new Map<String, Object>{ 'buttons' => metaButtons });

            return new Map<String, Object>{
                'type' => 'interactive',
                'interactive' => interactive
            };
        }

        // Builds an interactive list message
        // Meta allows up to 10 rows per section, 10 sections per list
        private Map<String, Object> buildListMessage(Map<String, Object> data) {
            String bodyText = (String) data.get('body');
            String buttonText = (String) data.get('buttonText');
            String headerText = (String) data.get('header');
            String footerText = (String) data.get('footer');
            List<Object> sections = (List<Object>) data.get('sections');

            List<Object> metaSections = new List<Object>();
            if (sections != null) {
                for (Object secObj : sections) {
                    Map<String, Object> section = (Map<String, Object>) secObj;
                    List<Object> rows = (List<Object>) section.get('rows');
                    List<Object> metaRows = new List<Object>();

                    if (rows != null) {
                        for (Object rowObj : rows) {
                            Map<String, Object> row = (Map<String, Object>) rowObj;
                            metaRows.add(new Map<String, Object>{
                                'id' => (String) row.get('id'),
                                'title' => truncate((String) row.get('title'), 24),
                                'description' => truncate((String) row.get('description'), 72)
                            });
                        }
                    }

                    metaSections.add(new Map<String, Object>{
                        'title' => (String) section.get('title'),
                        'rows' => metaRows
                    });
                }
            }

            Map<String, Object> interactive = new Map<String, Object>{
                'type' => 'list',
                'body' => new Map<String, Object>{ 'text' => bodyText != null ? bodyText : '' },
                'action' => new Map<String, Object>{
                    'button' => buttonText != null ? truncate(buttonText, 20) : 'Options',
                    'sections' => metaSections
                }
            };

            if (String.isNotBlank(headerText)) {
                interactive.put('header', new Map<String, Object>{
                    'type' => 'text',
                    'text' => headerText
                });
            }
            if (String.isNotBlank(footerText)) {
                interactive.put('footer', new Map<String, Object>{ 'text' => footerText });
            }

            return new Map<String, Object>{
                'type' => 'interactive',
                'interactive' => interactive
            };
        }

        // Builds a media message (image or video)
        private Map<String, Object> buildMediaMessage(Map<String, Object> data) {
            String mediaType = (String) data.get('mediaType');
            String url = (String) data.get('url');
            String caption = (String) data.get('caption');

            if (mediaType == null) mediaType = 'image';

            Map<String, Object> mediaObj = new Map<String, Object>{
                'link' => url
            };
            if (String.isNotBlank(caption)) {
                mediaObj.put('caption', caption);
            }

            return new Map<String, Object>{
                'type' => mediaType,
                mediaType => mediaObj
            };
        }

        // Builds carousel as multiple image messages (Meta doesn't support native carousel
        // in regular messages — only in template messages. We approximate with individual cards.)
        private List<Map<String, Object>> buildCarouselMessages(Map<String, Object> data) {
            List<Map<String, Object>> messages = new List<Map<String, Object>>();

            // Send header text if present
            String headerText = (String) data.get('header');
            if (String.isNotBlank(headerText)) {
                messages.add(buildTextMessage(headerText));
            }

            List<Object> cards = (List<Object>) data.get('cards');
            if (cards != null) {
                for (Object cardObj : cards) {
                    Map<String, Object> card = (Map<String, Object>) cardObj;
                    String imageUrl = (String) card.get('imageUrl');
                    String title = (String) card.get('title');
                    String description = (String) card.get('description');

                    // Build caption from title + description
                    String caption = '';
                    if (String.isNotBlank(title)) caption += '*' + title + '*\n';
                    if (String.isNotBlank(description)) caption += description;

                    if (String.isNotBlank(imageUrl)) {
                        Map<String, Object> imageObj = new Map<String, Object>{
                            'link' => imageUrl
                        };
                        if (String.isNotBlank(caption)) {
                            imageObj.put('caption', caption.trim());
                        }
                        messages.add(new Map<String, Object>{
                            'type' => 'image',
                            'image' => imageObj
                        });
                    } else {
                        // No image — send as text with formatting
                        messages.add(buildTextMessage(caption.trim()));
                    }
                }
            }

            return messages;
        }

        // ─── SEND TO WHATSAPP ────────────────────────────────────────────────────
        // Posts a formatted message to Meta's Send Message API.
        private void sendToWhatsApp(String phoneNumber, Map<String, Object> messageContent) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + META_NAMED_CREDENTIAL +
                '/v18.0/' + META_PHONE_NUMBER_ID + '/messages');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');

            Map<String, Object> body = new Map<String, Object>{
                'messaging_product' => 'whatsapp',
                'to' => phoneNumber
            };
            // Merge the message content into the body
            body.putAll(messageContent);

            req.setBody(JSON.serialize(body));

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200) {
                System.debug(LoggingLevel.ERROR,
                    'Meta Send Message failed (' + res.getStatusCode() + '): ' + res.getBody());
            }
        }

        // Updates the last activity timestamp on the session record
        private void updateSessionActivity(Id recordId) {
            WhatsApp_Session__c sessionUpdate = new WhatsApp_Session__c(
                Id = recordId,
                Last_Activity__c = DateTime.now()
            );
            update sessionUpdate;
        }

        // Truncates a string to a maximum length (Meta has strict length limits)
        private String truncate(String input, Integer maxLength) {
            if (input == null) return '';
            if (input.length() <= maxLength) return input;
            return input.substring(0, maxLength - 1) + '…';
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
