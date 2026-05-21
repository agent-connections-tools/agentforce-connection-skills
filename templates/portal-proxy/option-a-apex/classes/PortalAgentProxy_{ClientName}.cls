/**
 * Portal Agent Proxy for {ClientName}
 *
 * Apex controller that bridges an Experience Cloud LWC to the
 * Agentforce Agent API using the Continuation pattern (async callout).
 *
 * Why Continuation:
 *   Agent API responses take 5-15 seconds. A synchronous callout would
 *   block the transaction, accumulate CPU time toward governor limits,
 *   and freeze the LWC component. Continuation releases the transaction
 *   and resumes only when the callout returns.
 *
 * Auth:
 *   Inherits from Salesforce Identity — the user is already authenticated
 *   via Experience Cloud session. No separate auth middleware needed.
 *
 * Named Credentials required:
 *   - AgentAPI_{ClientName}: points to your org's Agent API base URL
 *     (e.g., https://yourorg.my.salesforce.com)
 *     Auth: Named Principal, OAuth 2.0 client_credentials
 */
public with sharing class PortalAgentProxy_{ClientName} {

    private static final String NAMED_CREDENTIAL = 'AgentAPI_{ClientName}';
    private static final String AGENT_ID = '{agentId}';
    private static final String SURFACE_ID = '{surfaceId}';
    private static final Integer SESSION_TTL_MINUTES = 30;

    // ─── Session Management ─────────────────────────────────────────────────
    // Uses Platform Cache (org partition) to store sessions across requests.
    // Falls back to custom object if cache is unavailable.

    private static String getSessionCacheKey(String userId) {
        return 'portal_session_' + userId.substring(0, 15);
    }

    private static Map<String, Object> getCachedSession(String userId) {
        String cacheKey = getSessionCacheKey(userId);
        try {
            String cached = (String) Cache.Org.get(cacheKey);
            if (cached != null) {
                return (Map<String, Object>) JSON.deserializeUntyped(cached);
            }
        } catch (Exception e) {
            // Cache unavailable — will create new session
        }
        return null;
    }

    private static void cacheSession(String userId, Map<String, Object> sessionData) {
        String cacheKey = getSessionCacheKey(userId);
        try {
            Cache.Org.put(cacheKey, JSON.serialize(sessionData), SESSION_TTL_MINUTES * 60);
        } catch (Exception e) {
            // Cache unavailable — session will be recreated next request
            System.debug(LoggingLevel.WARN, 'Failed to cache session: ' + e.getMessage());
        }
    }

    // ─── Create Session (Continuation) ──────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static Object startCreateSession() {
        String userId = UserInfo.getUserId();

        // Check for existing valid session
        Map<String, Object> existing = getCachedSession(userId);
        if (existing != null) {
            return existing;
        }

        // Create new session via Continuation
        Continuation con = new Continuation(60); // 60 second timeout
        con.continuationMethod = 'handleCreateSessionResponse';

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + NAMED_CREDENTIAL + '/einstein/ai-agent/v1/sessions');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{
            'externalSessionKey' => 'portal-' + userId + '-' + System.currentTimeMillis(),
            'instanceConfig' => new Map<String, Object>{
                'endpoint' => URL.getOrgDomainUrl().toExternalForm()
            },
            'streamingCapabilities' => new Map<String, Object>{
                'chunkTypes' => new List<String>{ 'Text' }
            },
            'bypassUser' => true
        }));

        con.addHttpRequest(req);
        return con;
    }

    @AuraEnabled(cacheable=false)
    public static Object handleCreateSessionResponse(List<String> labels, Object state) {
        String userId = UserInfo.getUserId();
        HttpResponse response = Continuation.getResponse(labels[0]);

        if (response.getStatusCode() != 200 && response.getStatusCode() != 201) {
            throw new AuraHandledException(
                'Failed to create agent session: ' + response.getStatusCode() + ' ' + response.getBody()
            );
        }

        Map<String, Object> responseBody = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
        String sessionId = (String) responseBody.get('sessionId');

        Map<String, Object> sessionData = new Map<String, Object>{
            'agentSessionId' => sessionId,
            'sequenceId' => 0
        };

        cacheSession(userId, sessionData);
        return sessionData;
    }

    // ─── Send Message (Continuation) ────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static Object startSendMessage(String agentSessionId, Integer sequenceId, String userMessage) {
        if (String.isBlank(userMessage)) {
            throw new AuraHandledException('Message is required');
        }

        Continuation con = new Continuation(120); // 120 second timeout for agent reasoning
        con.continuationMethod = 'handleSendMessageResponse';
        con.state = JSON.serialize(new Map<String, Object>{
            'agentSessionId' => agentSessionId,
            'sequenceId' => sequenceId
        });

        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            'callout:' + NAMED_CREDENTIAL +
            '/einstein/ai-agent/v1/sessions/' + agentSessionId + '/messages'
        );
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(new Map<String, Object>{
            'message' => new Map<String, Object>{
                'sequenceId' => sequenceId,
                'type' => 'Text',
                'text' => userMessage
            },
            'variables' => new List<Object>(),
            'surfaceType' => 'Custom',
            'surfaceId' => SURFACE_ID
        }));

        con.addHttpRequest(req);
        return con;
    }

    @AuraEnabled(cacheable=false)
    public static Object handleSendMessageResponse(List<String> labels, Object state) {
        String userId = UserInfo.getUserId();
        HttpResponse response = Continuation.getResponse(labels[0]);

        if (response.getStatusCode() != 200) {
            throw new AuraHandledException(
                'Agent API error: ' + response.getStatusCode() + ' ' + response.getBody()
            );
        }

        // Parse agent response
        Map<String, Object> agentResponse = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());

        // Update cached session sequence
        Map<String, Object> stateMap = (Map<String, Object>) JSON.deserializeUntyped((String) state);
        Integer newSequenceId = (Integer) stateMap.get('sequenceId');
        String agentSessionId = (String) stateMap.get('agentSessionId');

        Map<String, Object> sessionData = new Map<String, Object>{
            'agentSessionId' => agentSessionId,
            'sequenceId' => newSequenceId
        };
        cacheSession(userId, sessionData);

        // Parse and return structured responses
        return parseAgentResponse(agentResponse);
    }

    // ─── Response Parsing ───────────────────────────────────────────────────

    private static List<Map<String, Object>> parseAgentResponse(Map<String, Object> agentResponse) {
        List<Map<String, Object>> responses = new List<Map<String, Object>>();
        List<Object> messages = (List<Object>) agentResponse.get('messages');

        if (messages == null) {
            responses.add(new Map<String, Object>{
                'type' => 'text',
                'content' => 'I processed your request but have nothing to display.'
            });
            return responses;
        }

        for (Object msgObj : messages) {
            Map<String, Object> msg = (Map<String, Object>) msgObj;
            String msgType = (String) msg.get('type');

            if (msgType == 'Text') {
                String text = (String) msg.get('text');
                Map<String, Object> structured = tryParseStructured(text);
                if (structured != null) {
                    responses.add(structured);
                } else {
                    responses.add(new Map<String, Object>{
                        'type' => 'text',
                        'content' => text
                    });
                }
            } else if (msgType == 'RichContent') {
                Map<String, Object> content = (Map<String, Object>) msg.get('content');
                if (content != null) {
                    responses.add(content);
                }
            }
        }

        if (responses.isEmpty()) {
            responses.add(new Map<String, Object>{
                'type' => 'text',
                'content' => 'I processed your request but have nothing to display.'
            });
        }

        return responses;
    }

    private static Map<String, Object> tryParseStructured(String text) {
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(text);
            if (parsed.containsKey('type') || parsed.containsKey('responseFormatType')) {
                return parsed;
            }
        } catch (Exception e) {
            // Not JSON — plain text
        }
        return null;
    }

    // ─── Reset Session ──────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static void resetSession() {
        String userId = UserInfo.getUserId();
        String cacheKey = getSessionCacheKey(userId);
        try {
            Cache.Org.remove(cacheKey);
        } catch (Exception e) {
            // Cache unavailable — no-op
        }
    }
}
