/**
 * Instagram Webhook Handler for {ClientName}
 *
 * This Apex REST class bridges Meta's Instagram Messaging API to the Salesforce Agent API.
 * It receives incoming Instagram DMs, routes them to an Agentforce agent,
 * and sends the agent's rich responses back to Instagram.
 *
 * Deployment: Expose via Salesforce Site or Digital Experience (see README).
 * Auth: Uses Named Credentials for both Meta API and Salesforce Agent API.
 */
@RestResource(urlMapping='/instagram/{ClientName}/webhook')
global with sharing class InstagramWebhook_{ClientName} {

    private static final String META_NAMED_CREDENTIAL = 'Meta_Instagram_API';
    private static final String AGENT_NAMED_CREDENTIAL = 'Agentforce_Agent_API';
    private static final String VERIFY_TOKEN = Instagram_Config_{ClientName}__mdt.getInstance('Default').Verify_Token__c;
    private static final String AGENT_ID = Instagram_Config_{ClientName}__mdt.getInstance('Default').Agent_Id__c;
    private static final String SURFACE_ID = '{surfaceId}';
    private static final String INSTAGRAM_ID = Instagram_Config_{ClientName}__mdt.getInstance('Default').Instagram_Id__c;

    @HttpGet
    global static void doGet() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        String mode = req.params.get('hub.mode');
        String token = req.params.get('hub.verify_token');
        String challenge = req.params.get('hub.challenge');

        if (mode == 'subscribe' && token == VERIFY_TOKEN) {
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(challenge);
        } else {
            res.statusCode = 403;
            res.responseBody = Blob.valueOf('Verification failed');
        }
    }

    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        res.statusCode = 200;
        res.responseBody = Blob.valueOf('OK');

        String body = req.requestBody.toString();
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(body);

        MessageInfo msgInfo = extractMessage(payload);

        if (msgInfo == null || String.isBlank(msgInfo.text)) {
            return;
        }

        System.enqueueJob(new InstagramMessageProcessor(msgInfo));
    }

    // Instagram uses: entry[].messaging[].sender.id + entry[].messaging[].message.text
    private static MessageInfo extractMessage(Map<String, Object> payload) {
        try {
            List<Object> entryList = (List<Object>) payload.get('entry');
            if (entryList == null || entryList.isEmpty()) return null;

            Map<String, Object> entry = (Map<String, Object>) entryList[0];
            List<Object> messagingList = (List<Object>) entry.get('messaging');
            if (messagingList == null || messagingList.isEmpty()) return null;

            Map<String, Object> messaging = (Map<String, Object>) messagingList[0];

            // Get sender ID
            Map<String, Object> sender = (Map<String, Object>) messaging.get('sender');
            if (sender == null) return null;
            String senderId = (String) sender.get('id');

            String text = '';

            // Check for regular message
            Map<String, Object> message = (Map<String, Object>) messaging.get('message');
            if (message != null) {
                // Skip echo messages
                if (message.containsKey('is_echo') && (Boolean) message.get('is_echo')) {
                    return null;
                }

                // Quick reply payload takes priority
                Map<String, Object> quickReply = (Map<String, Object>) message.get('quick_reply');
                if (quickReply != null) {
                    text = (String) quickReply.get('payload');
                } else {
                    text = (String) message.get('text');
                }
            }

            // Check for postback (button tap)
            if (String.isBlank(text)) {
                Map<String, Object> postback = (Map<String, Object>) messaging.get('postback');
                if (postback != null) {
                    text = (String) postback.get('payload');
                }
            }

            if (String.isBlank(text)) return null;

            MessageInfo info = new MessageInfo();
            info.senderId = senderId;
            info.text = text;
            return info;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to extract Instagram message: ' + e.getMessage());
            return null;
        }
    }

    global class MessageInfo {
        public String senderId;
        public String text;
    }

    global class InstagramMessageProcessor implements Queueable, Database.AllowsCallouts {
        private MessageInfo msgInfo;

        public InstagramMessageProcessor(MessageInfo msgInfo) {
            this.msgInfo = msgInfo;
        }

        public void execute(QueueableContext ctx) {
            try {
                SessionInfo session = getOrCreateSession(msgInfo.senderId);
                String agentResponse = callAgentAPI(session, msgInfo.text);
                List<Map<String, Object>> instagramMessages = convertToInstagramFormat(agentResponse);

                for (Map<String, Object> igMsg : instagramMessages) {
                    sendToInstagram(msgInfo.senderId, igMsg);
                }

                updateSessionActivity(session.recordId);

            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Instagram processing error: ' + e.getMessage());
                Map<String, Object> errorMsg = new Map<String, Object>{
                    'text' => 'I\'m having trouble right now. Please try again in a moment.'
                };
                sendToInstagram(msgInfo.senderId, errorMsg);
            }
        }

        private SessionInfo getOrCreateSession(String senderId) {
            DateTime cutoff = DateTime.now().addMinutes(-30);
            List<Instagram_Session__c> sessions = [
                SELECT Id, Agent_Session_Id__c, Last_Sequence_Id__c
                FROM Instagram_Session__c
                WHERE Sender_Id__c = :senderId
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

            String newSessionId = createAgentSession();

            Instagram_Session__c sessionRecord = new Instagram_Session__c(
                Sender_Id__c = senderId,
                Agent_Session_Id__c = newSessionId,
                Last_Sequence_Id__c = 1,
                Last_Activity__c = DateTime.now()
            );
            upsert sessionRecord Sender_Id__c;

            SessionInfo info = new SessionInfo();
            info.recordId = sessionRecord.Id;
            info.agentSessionId = newSessionId;
            info.sequenceId = 1;
            info.isNew = true;
            return info;
        }

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
                'bypassUser' => true
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

        private String generateSessionKey() {
            return 'ig-' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 16);
        }

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
            req.setTimeout(120000);

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200) {
                throw new CalloutException('Agent API error (' + res.getStatusCode() + '): ' + res.getBody());
            }

            Instagram_Session__c sessionUpdate = new Instagram_Session__c(
                Id = session.recordId,
                Last_Sequence_Id__c = nextSequenceId
            );
            update sessionUpdate;

            return res.getBody();
        }

        private List<Map<String, Object>> convertToInstagramFormat(String agentResponseBody) {
            List<Map<String, Object>> messages = new List<Map<String, Object>>();

            Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(agentResponseBody);
            List<Object> agentMessages = (List<Object>) responseMap.get('messages');
            if (agentMessages == null || agentMessages.isEmpty()) {
                return messages;
            }

            for (Object msgObj : agentMessages) {
                Map<String, Object> msg = (Map<String, Object>) msgObj;
                String msgType = (String) msg.get('type');

                if (msgType == 'Text') {
                    String text = (String) msg.get('text');
                    Map<String, Object> structured = tryParseStructuredResponse(text);

                    if (structured != null) {
                        messages.addAll(translateStructuredResponse(structured));
                    } else {
                        messages.add(new Map<String, Object>{ 'text' => text });
                    }
                } else if (msgType == 'RichContent') {
                    Map<String, Object> content = (Map<String, Object>) msg.get('content');
                    if (content != null) {
                        messages.addAll(translateStructuredResponse(content));
                    }
                }
            }

            if (messages.isEmpty()) {
                messages.add(new Map<String, Object>{ 'text' => 'I processed your request but have nothing to display.' });
            }

            return messages;
        }

        private Map<String, Object> tryParseStructuredResponse(String text) {
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(text);
                if (parsed.containsKey('type') || parsed.containsKey('responseFormatType')) {
                    return parsed;
                }
            } catch (Exception e) {
                // Not JSON
            }
            return null;
        }

        private List<Map<String, Object>> translateStructuredResponse(Map<String, Object> structured) {
            List<Map<String, Object>> messages = new List<Map<String, Object>>();

            String responseType = (String) structured.get('type');
            if (responseType == null) {
                responseType = (String) structured.get('responseFormatType');
            }

            if (responseType == 'InstagramQuickReply') {
                messages.add(buildQuickReplyMessage(structured));
            } else if (responseType == 'InstagramGenericTemplate') {
                messages.add(buildGenericTemplate(structured));
            } else if (responseType == 'InstagramButtonTemplate') {
                messages.add(buildButtonTemplate(structured));
            } else if (responseType == 'InstagramMediaTemplate') {
                messages.add(buildMediaTemplate(structured));
            } else {
                String bodyText = (String) structured.get('text');
                if (bodyText == null) bodyText = (String) structured.get('body');
                if (bodyText == null) bodyText = JSON.serialize(structured);
                messages.add(new Map<String, Object>{ 'text' => bodyText });
            }

            return messages;
        }

        // Quick reply: text + button pills
        private Map<String, Object> buildQuickReplyMessage(Map<String, Object> data) {
            String text = (String) data.get('text');
            List<Object> buttons = (List<Object>) data.get('buttons');

            List<Object> quickReplies = new List<Object>();
            if (buttons != null) {
                Integer count = 0;
                for (Object btnObj : buttons) {
                    if (count >= 13) break;
                    Map<String, Object> btn = (Map<String, Object>) btnObj;
                    quickReplies.add(new Map<String, Object>{
                        'content_type' => 'text',
                        'title' => truncate((String) btn.get('title'), 20),
                        'payload' => btn.get('payload') != null ? (String) btn.get('payload') : (String) btn.get('title')
                    });
                    count++;
                }
            }

            return new Map<String, Object>{
                'text' => text != null ? text : '',
                'quick_replies' => quickReplies
            };
        }

        // Generic template: carousel of cards
        private Map<String, Object> buildGenericTemplate(Map<String, Object> data) {
            List<Object> elements = (List<Object>) data.get('elements');
            List<Object> metaElements = new List<Object>();

            if (elements != null) {
                Integer count = 0;
                for (Object elObj : elements) {
                    if (count >= 10) break;
                    Map<String, Object> el = (Map<String, Object>) elObj;

                    Map<String, Object> element = new Map<String, Object>{
                        'title' => truncate((String) el.get('title'), 80)
                    };

                    String subtitle = (String) el.get('subtitle');
                    if (String.isNotBlank(subtitle)) {
                        element.put('subtitle', truncate(subtitle, 80));
                    }

                    String imageUrl = (String) el.get('image_url');
                    if (String.isNotBlank(imageUrl)) {
                        element.put('image_url', imageUrl);
                    }

                    List<Object> elButtons = (List<Object>) el.get('buttons');
                    if (elButtons != null && !elButtons.isEmpty()) {
                        List<Object> metaButtons = new List<Object>();
                        Integer btnCount = 0;
                        for (Object btnObj : elButtons) {
                            if (btnCount >= 3) break;
                            Map<String, Object> btn = (Map<String, Object>) btnObj;
                            Map<String, Object> metaBtn = new Map<String, Object>{
                                'type' => (String) btn.get('type'),
                                'title' => truncate((String) btn.get('title'), 20)
                            };
                            if ((String) btn.get('type') == 'web_url') {
                                metaBtn.put('url', (String) btn.get('url'));
                            }
                            if ((String) btn.get('type') == 'postback') {
                                metaBtn.put('payload', (String) btn.get('payload'));
                            }
                            metaButtons.add(metaBtn);
                            btnCount++;
                        }
                        element.put('buttons', metaButtons);
                    }

                    metaElements.add(element);
                    count++;
                }
            }

            return new Map<String, Object>{
                'attachment' => new Map<String, Object>{
                    'type' => 'template',
                    'payload' => new Map<String, Object>{
                        'template_type' => 'generic',
                        'elements' => metaElements
                    }
                }
            };
        }

        // Button template: text + up to 3 buttons
        private Map<String, Object> buildButtonTemplate(Map<String, Object> data) {
            String text = (String) data.get('text');
            List<Object> buttons = (List<Object>) data.get('buttons');

            List<Object> metaButtons = new List<Object>();
            if (buttons != null) {
                Integer count = 0;
                for (Object btnObj : buttons) {
                    if (count >= 3) break;
                    Map<String, Object> btn = (Map<String, Object>) btnObj;
                    Map<String, Object> metaBtn = new Map<String, Object>{
                        'type' => (String) btn.get('type'),
                        'title' => truncate((String) btn.get('title'), 20)
                    };
                    if ((String) btn.get('type') == 'web_url') {
                        metaBtn.put('url', (String) btn.get('url'));
                    }
                    if ((String) btn.get('type') == 'postback') {
                        metaBtn.put('payload', (String) btn.get('payload'));
                    }
                    metaButtons.add(metaBtn);
                    count++;
                }
            }

            return new Map<String, Object>{
                'attachment' => new Map<String, Object>{
                    'type' => 'template',
                    'payload' => new Map<String, Object>{
                        'template_type' => 'button',
                        'text' => text != null ? truncate(text, 640) : '',
                        'buttons' => metaButtons
                    }
                }
            };
        }

        // Media template: image or video with optional button
        private Map<String, Object> buildMediaTemplate(Map<String, Object> data) {
            String mediaType = (String) data.get('media_type');
            String url = (String) data.get('url');
            List<Object> buttons = (List<Object>) data.get('buttons');

            if (mediaType == null) mediaType = 'image';

            Map<String, Object> element = new Map<String, Object>{
                'media_type' => mediaType,
                'url' => url
            };

            if (buttons != null && !buttons.isEmpty()) {
                Map<String, Object> btn = (Map<String, Object>) buttons[0];
                Map<String, Object> metaBtn = new Map<String, Object>{
                    'type' => (String) btn.get('type'),
                    'title' => truncate((String) btn.get('title'), 20)
                };
                if ((String) btn.get('type') == 'web_url') {
                    metaBtn.put('url', (String) btn.get('url'));
                }
                if ((String) btn.get('type') == 'postback') {
                    metaBtn.put('payload', (String) btn.get('payload'));
                }
                element.put('buttons', new List<Object>{ metaBtn });
            }

            return new Map<String, Object>{
                'attachment' => new Map<String, Object>{
                    'type' => 'template',
                    'payload' => new Map<String, Object>{
                        'template_type' => 'media_template',
                        'elements' => new List<Object>{ element }
                    }
                }
            };
        }

        private void sendToInstagram(String recipientId, Map<String, Object> messageContent) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + META_NAMED_CREDENTIAL +
                '/v21.0/' + INSTAGRAM_ID + '/messages');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');

            Map<String, Object> body = new Map<String, Object>{
                'recipient' => new Map<String, Object>{ 'id' => recipientId },
                'message' => messageContent
            };

            req.setBody(JSON.serialize(body));

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200) {
                System.debug(LoggingLevel.ERROR,
                    'Instagram Send failed (' + res.getStatusCode() + '): ' + res.getBody());
            }
        }

        private void updateSessionActivity(Id recordId) {
            Instagram_Session__c sessionUpdate = new Instagram_Session__c(
                Id = recordId,
                Last_Activity__c = DateTime.now()
            );
            update sessionUpdate;
        }

        private String truncate(String input, Integer maxLength) {
            if (input == null) return '';
            if (input.length() <= maxLength) return input;
            return input.substring(0, maxLength - 1) + '…';
        }
    }

    private class SessionInfo {
        public Id recordId;
        public String agentSessionId;
        public Integer sequenceId;
        public Boolean isNew;
    }
}
