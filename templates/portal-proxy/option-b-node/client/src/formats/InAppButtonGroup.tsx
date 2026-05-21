import './formats.css';

interface GroupButton {
  id: string;
  label: string;
  style?: 'primary' | 'secondary' | 'danger';
  action: 'reply' | 'link' | 'submit';
  value: string;
}

interface Props {
  data: {
    body?: string;
    buttons?: GroupButton[];
    [key: string]: unknown;
  };
  onButtonAction: (action: string, value: string) => void;
}

export function InAppButtonGroup({ data, onButtonAction }: Props) {
  const buttons = data.buttons || [];

  return (
    <div className="format-btngroup" role="group" aria-label="Action choices">
      {data.body && <p className="format-btngroup__body">{data.body}</p>}
      <div className="format-btngroup__buttons">
        {buttons.map(btn => (
          <button
            key={btn.id}
            className={`format-btn format-btn--${btn.style || 'secondary'}`}
            onClick={() => onButtonAction(btn.action, btn.value)}
            aria-label={btn.label}
          >
            {btn.label}
          </button>
        ))}
      </div>
    </div>
  );
}
