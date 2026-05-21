import { LightningElement, track } from 'lwc';
import startCreateSession from '@salesforce/apexContinuation/PortalAgentProxy_{ClientName}.startCreateSession';
import startSendMessage from '@salesforce/apexContinuation/PortalAgentProxy_{ClientName}.startSendMessage';
import resetSession from '@salesforce/apex/PortalAgentProxy_{ClientName}.resetSession';

export default class PortalChat_{ClientName} extends LightningElement {
    @track messages = [];
    @track inputValue = '';
    @track isLoading = false;
    @track errorMessage = null;

    session = null;

    async connectedCallback() {
        await this.initSession();
    }

    async initSession() {
        try {
            const result = await startCreateSession();
            this.session = result;
        } catch (error) {
            this.errorMessage = 'Unable to connect. Please refresh the page.';
            console.error('Session init failed:', error);
        }
    }

    handleInputChange(event) {
        this.inputValue = event.target.value;
    }

    handleKeyDown(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.sendMessage();
        }
    }

    async sendMessage() {
        const text = this.inputValue.trim();
        if (!text || this.isLoading) return;

        this.inputValue = '';
        this.errorMessage = null;

        // Add user message
        this.messages = [...this.messages, {
            id: 'user-' + Date.now(),
            role: 'user',
            content: text,
        }];

        this.isLoading = true;

        try {
            if (!this.session) {
                await this.initSession();
            }

            const sequenceId = (this.session.sequenceId || 0) + 1;
            this.session.sequenceId = sequenceId;

            const responses = await startSendMessage({
                agentSessionId: this.session.agentSessionId,
                sequenceId: sequenceId,
                userMessage: text,
            });

            this.messages = [...this.messages, {
                id: 'agent-' + Date.now(),
                role: 'agent',
                content: responses,
            }];

        } catch (error) {
            const errMsg = error.body?.message || error.message || 'Something went wrong.';
            this.errorMessage = errMsg;

            // If session expired, reset and retry
            if (errMsg.includes('session') || errMsg.includes('404')) {
                this.session = null;
                this.errorMessage = 'Session expired. Reconnecting...';
                await this.initSession();
            }
        } finally {
            this.isLoading = false;
            this.scrollToBottom();
        }
    }

    async handleReset() {
        try {
            await resetSession();
            this.session = null;
            this.messages = [];
            this.errorMessage = null;
            await this.initSession();
        } catch (error) {
            console.error('Reset failed:', error);
        }
    }

    handleButtonAction(event) {
        const { action, value } = event.detail;
        if (action === 'reply' || action === 'submit') {
            this.inputValue = value;
            this.sendMessage();
        } else if (action === 'link') {
            window.open(value, '_blank', 'noopener');
        }
    }

    handleFormSubmit(event) {
        const data = event.detail;
        const summary = Object.entries(data)
            .map(([key, val]) => `${key}: ${val}`)
            .join(', ');
        this.inputValue = summary;
        this.sendMessage();
    }

    scrollToBottom() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const container = this.template.querySelector('.chat-messages');
            if (container) {
                container.scrollTop = container.scrollHeight;
            }
        }, 100);
    }

    get isSendDisabled() {
        return this.isLoading || !this.inputValue.trim();
    }

    get hasMessages() {
        return this.messages.length > 0;
    }
}
