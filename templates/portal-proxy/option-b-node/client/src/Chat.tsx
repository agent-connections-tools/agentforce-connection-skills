import { useState, useRef, useEffect, KeyboardEvent } from 'react';
import { FormatRenderer } from './FormatRenderer';
import './Chat.css';

interface Message {
  id: string;
  role: 'user' | 'agent';
  content: string | AgentResponse[];
  timestamp: number;
}

export interface AgentResponse {
  type: string;
  responseFormatType?: string;
  [key: string]: unknown;
}

export function Chat() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  async function sendMessage() {
    const text = input.trim();
    if (!text || loading) return;

    setInput('');
    setError(null);

    const userMsg: Message = {
      id: `user-${Date.now()}`,
      role: 'user',
      content: text,
      timestamp: Date.now(),
    };
    setMessages(prev => [...prev, userMsg]);
    setLoading(true);

    try {
      const res = await fetch('/api/agent/message', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          // In production, include: 'Authorization': `Bearer ${token}`
        },
        body: JSON.stringify({ message: text }),
      });

      if (!res.ok) {
        const errData = await res.json().catch(() => ({}));
        if (res.status === 401) {
          setError('Your session has expired. Please log in again.');
        } else {
          setError(errData.message || 'Something went wrong. Please try again.');
        }
        return;
      }

      const data = await res.json();

      const agentMsg: Message = {
        id: `agent-${Date.now()}`,
        role: 'agent',
        content: data.responses,
        timestamp: Date.now(),
      };
      setMessages(prev => [...prev, agentMsg]);

    } catch {
      setError('Unable to connect. Retrying...');
      // Retry once after 2 seconds
      setTimeout(async () => {
        try {
          const retryRes = await fetch('/api/agent/message', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ message: text }),
          });
          if (retryRes.ok) {
            const data = await retryRes.json();
            const agentMsg: Message = {
              id: `agent-${Date.now()}`,
              role: 'agent',
              content: data.responses,
              timestamp: Date.now(),
            };
            setMessages(prev => [...prev, agentMsg]);
            setError(null);
          } else {
            setError('Unable to connect. Please check your connection and try again.');
          }
        } catch {
          setError('Unable to connect. Please check your connection and try again.');
        }
      }, 2000);
    } finally {
      setLoading(false);
      inputRef.current?.focus();
    }
  }

  function handleKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  }

  function handleButtonAction(action: string, value: string) {
    if (action === 'reply') {
      setInput(value);
      sendMessage();
    } else if (action === 'link') {
      window.open(value, '_blank', 'noopener');
    } else if (action === 'submit') {
      setInput(value);
      sendMessage();
    }
  }

  function handleFormSubmit(data: Record<string, string>) {
    const summary = Object.entries(data)
      .map(([key, val]) => `${key}: ${val}`)
      .join(', ');
    setInput(summary);
    sendMessage();
  }

  return (
    <div className="chat">
      <div className="chat-messages" role="log" aria-live="polite" aria-label="Conversation">
        {messages.map(msg => (
          <div key={msg.id} className={`chat-message chat-message--${msg.role}`}>
            {msg.role === 'user' ? (
              <div className="chat-bubble chat-bubble--user">{msg.content as string}</div>
            ) : (
              <div className="chat-bubble chat-bubble--agent">
                {(msg.content as AgentResponse[]).map((response, i) => (
                  <FormatRenderer
                    key={i}
                    response={response}
                    onButtonAction={handleButtonAction}
                    onFormSubmit={handleFormSubmit}
                  />
                ))}
              </div>
            )}
          </div>
        ))}

        {loading && (
          <div className="chat-message chat-message--agent">
            <div className="chat-bubble chat-bubble--agent chat-loading" aria-label="Agent is thinking">
              <span className="dot" /><span className="dot" /><span className="dot" />
            </div>
          </div>
        )}

        {error && (
          <div className="chat-error" role="alert">{error}</div>
        )}

        <div ref={messagesEndRef} />
      </div>

      <div className="chat-input-area">
        <textarea
          ref={inputRef}
          className="chat-input"
          value={input}
          onChange={e => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Type a message..."
          rows={1}
          disabled={loading}
          aria-label="Message input"
        />
        <button
          className="chat-send"
          onClick={sendMessage}
          disabled={loading || !input.trim()}
          aria-label="Send message"
        >
          Send
        </button>
      </div>
    </div>
  );
}
