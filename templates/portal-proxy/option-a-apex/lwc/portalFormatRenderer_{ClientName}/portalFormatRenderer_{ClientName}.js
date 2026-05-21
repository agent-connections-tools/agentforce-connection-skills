import { LightningElement, api } from 'lwc';

export default class PortalFormatRenderer_{ClientName} extends LightningElement {
    @api responses = [];

    get processedResponses() {
        return (this.responses || []).map((resp, index) => {
            const formatType = resp.responseFormatType || resp.type;
            return {
                key: `resp-${index}`,
                data: resp,
                isText: formatType === 'text',
                isCard: formatType === 'InAppCard',
                isList: formatType === 'InAppList',
                isButtonGroup: formatType === 'InAppButtonGroup',
                isForm: formatType === 'InAppForm',
                isCarousel: formatType === 'InAppCarousel',
                isUnknown: !['text', 'InAppCard', 'InAppList', 'InAppButtonGroup', 'InAppForm', 'InAppCarousel'].includes(formatType),
            };
        });
    }

    // ─── InAppCard helpers ───────────────────────────────────────────────
    getCardButtons(data) {
        return data.buttons || [];
    }

    // ─── InAppList helpers ──────────────────────────────────────────────
    getListItems(data) {
        return (data.items || []).map(item => ({
            ...item,
            hasAction: !!item.action,
            hasIcon: !!item.iconUrl,
        }));
    }

    // ─── InAppButtonGroup helpers ───────────────────────────────────────
    getGroupButtons(data) {
        return (data.buttons || []).map(btn => ({
            ...btn,
            variant: btn.style === 'primary' ? 'brand' :
                     btn.style === 'danger' ? 'destructive' : 'neutral',
        }));
    }

    // ─── InAppForm helpers ──────────────────────────────────────────────
    getFormFields(data) {
        return (data.fields || []).map(field => ({
            ...field,
            isText: field.type === 'text' || field.type === 'email' || field.type === 'number',
            isSelect: field.type === 'select',
            isCheckbox: field.type === 'checkbox',
            selectOptions: (field.options || []).map(opt => ({
                label: opt.label,
                value: opt.value,
            })),
        }));
    }

    // ─── InAppCarousel helpers ──────────────────────────────────────────
    getCarouselCards(data) {
        return data.cards || [];
    }

    // ─── Event Handlers ─────────────────────────────────────────────────
    handleButtonClick(event) {
        const action = event.currentTarget.dataset.action;
        const value = event.currentTarget.dataset.value;
        this.dispatchEvent(new CustomEvent('buttonaction', {
            detail: { action, value },
            bubbles: true,
            composed: true,
        }));
    }

    handleListItemClick(event) {
        const actionType = event.currentTarget.dataset.actionType;
        const actionValue = event.currentTarget.dataset.actionValue;
        if (actionType && actionValue) {
            this.dispatchEvent(new CustomEvent('buttonaction', {
                detail: { action: actionType, value: actionValue },
                bubbles: true,
                composed: true,
            }));
        }
    }

    handleFormSubmit(event) {
        event.preventDefault();
        const formData = {};
        const inputs = this.template.querySelectorAll('[data-field-id]');
        let valid = true;

        inputs.forEach(input => {
            const fieldId = input.dataset.fieldId;
            if (input.type === 'checkbox') {
                formData[fieldId] = input.checked ? 'true' : 'false';
            } else {
                formData[fieldId] = input.value;
            }
            if (input.required && !input.value) {
                input.reportValidity();
                valid = false;
            }
        });

        if (valid) {
            this.dispatchEvent(new CustomEvent('formsubmit', {
                detail: formData,
                bubbles: true,
                composed: true,
            }));
        }
    }

    // ─── Carousel scroll ────────────────────────────────────────────────
    handleScrollLeft() {
        const track = this.template.querySelector('.carousel-track');
        if (track) track.scrollBy({ left: -260, behavior: 'smooth' });
    }

    handleScrollRight() {
        const track = this.template.querySelector('.carousel-track');
        if (track) track.scrollBy({ left: 260, behavior: 'smooth' });
    }

    // Unknown format fallback text
    getUnknownText(data) {
        return data.body || data.content || JSON.stringify(data);
    }
}
