import { useState } from 'react';
import './formats.css';

interface FormField {
  id: string;
  label: string;
  type: 'text' | 'email' | 'number' | 'select' | 'checkbox';
  placeholder?: string;
  required?: boolean;
  pattern?: string;
  options?: { label: string; value: string }[];
}

interface Props {
  data: {
    title?: string;
    description?: string;
    fields?: FormField[];
    submitLabel?: string;
    cancelLabel?: string;
    [key: string]: unknown;
  };
  onFormSubmit: (data: Record<string, string>) => void;
}

export function InAppForm({ data, onFormSubmit }: Props) {
  const fields = data.fields || [];
  const [values, setValues] = useState<Record<string, string>>({});
  const [errors, setErrors] = useState<Record<string, string>>({});

  function handleChange(fieldId: string, value: string) {
    setValues(prev => ({ ...prev, [fieldId]: value }));
    setErrors(prev => {
      const next = { ...prev };
      delete next[fieldId];
      return next;
    });
  }

  function validate(): boolean {
    const newErrors: Record<string, string> = {};
    for (const field of fields) {
      const val = values[field.id] || '';
      if (field.required && !val) {
        newErrors[field.id] = 'Required';
      } else if (field.pattern && val) {
        const regex = new RegExp(field.pattern);
        if (!regex.test(val)) {
          newErrors[field.id] = 'Invalid format';
        }
      }
    }
    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (validate()) {
      onFormSubmit(values);
    }
  }

  return (
    <form className="format-form" onSubmit={handleSubmit} aria-label={data.title || 'Form'}>
      {data.title && <h3 className="format-form__title">{data.title}</h3>}
      {data.description && <p className="format-form__desc">{data.description}</p>}

      <div className="format-form__fields">
        {fields.map(field => (
          <div key={field.id} className="format-form__field">
            <label className="format-form__label" htmlFor={`field-${field.id}`}>
              {field.label}
              {field.required && <span className="format-form__required" aria-label="required"> *</span>}
            </label>

            {field.type === 'select' ? (
              <select
                id={`field-${field.id}`}
                className="format-form__input"
                value={values[field.id] || ''}
                onChange={e => handleChange(field.id, e.target.value)}
                required={field.required}
                aria-invalid={!!errors[field.id]}
              >
                <option value="">{field.placeholder || 'Select...'}</option>
                {(field.options || []).map(opt => (
                  <option key={opt.value} value={opt.value}>{opt.label}</option>
                ))}
              </select>
            ) : field.type === 'checkbox' ? (
              <label className="format-form__checkbox">
                <input
                  id={`field-${field.id}`}
                  type="checkbox"
                  checked={values[field.id] === 'true'}
                  onChange={e => handleChange(field.id, e.target.checked ? 'true' : 'false')}
                  aria-invalid={!!errors[field.id]}
                />
                <span>{field.placeholder || ''}</span>
              </label>
            ) : (
              <input
                id={`field-${field.id}`}
                className="format-form__input"
                type={field.type}
                value={values[field.id] || ''}
                onChange={e => handleChange(field.id, e.target.value)}
                placeholder={field.placeholder}
                required={field.required}
                pattern={field.pattern}
                aria-invalid={!!errors[field.id]}
              />
            )}

            {errors[field.id] && (
              <span className="format-form__error" role="alert">{errors[field.id]}</span>
            )}
          </div>
        ))}
      </div>

      <div className="format-form__actions">
        <button type="submit" className="format-btn format-btn--primary">
          {data.submitLabel || 'Submit'}
        </button>
        {data.cancelLabel && (
          <button type="button" className="format-btn format-btn--secondary">
            {data.cancelLabel}
          </button>
        )}
      </div>
    </form>
  );
}
