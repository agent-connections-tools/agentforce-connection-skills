import './formats.css';

interface CardButton {
  id: string;
  label: string;
  action: 'link' | 'reply' | 'submit';
  value: string;
}

interface Props {
  data: {
    title?: string;
    body?: string;
    imageUrl?: string;
    buttons?: CardButton[];
    [key: string]: unknown;
  };
  onButtonAction: (action: string, value: string) => void;
}

export function InAppCard({ data, onButtonAction }: Props) {
  return (
    <div className="format-card" role="article" aria-label={data.title || 'Card'}>
      {data.imageUrl && (
        <img className="format-card__image" src={data.imageUrl} alt="" />
      )}
      <div className="format-card__content">
        {data.title && <h3 className="format-card__title">{data.title}</h3>}
        {data.body && <p className="format-card__body">{data.body}</p>}
      </div>
      {data.buttons && data.buttons.length > 0 && (
        <div className="format-card__actions">
          {data.buttons.map(btn => (
            <button
              key={btn.id}
              className="format-btn"
              onClick={() => onButtonAction(btn.action, btn.value)}
              aria-label={btn.label}
            >
              {btn.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
