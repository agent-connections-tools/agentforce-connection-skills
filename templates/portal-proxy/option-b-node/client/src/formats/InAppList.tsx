import './formats.css';

interface ListItem {
  id: string;
  title: string;
  subtitle?: string;
  iconUrl?: string;
  action?: { type: 'link' | 'reply'; value: string };
}

interface Props {
  data: {
    title?: string;
    items?: ListItem[];
    [key: string]: unknown;
  };
  onButtonAction: (action: string, value: string) => void;
}

export function InAppList({ data, onButtonAction }: Props) {
  const items = data.items || [];

  return (
    <div className="format-list" role="list" aria-label={data.title || 'List'}>
      {data.title && <h3 className="format-list__title">{data.title}</h3>}
      {items.map(item => (
        <div
          key={item.id}
          className={`format-list__item ${item.action ? 'format-list__item--clickable' : ''}`}
          role="listitem"
          tabIndex={item.action ? 0 : undefined}
          onClick={() => item.action && onButtonAction(item.action.type, item.action.value)}
          onKeyDown={e => {
            if (e.key === 'Enter' && item.action) {
              onButtonAction(item.action.type, item.action.value);
            }
          }}
          aria-label={item.title}
        >
          {item.iconUrl && (
            <img className="format-list__icon" src={item.iconUrl} alt="" />
          )}
          <div className="format-list__text">
            <span className="format-list__item-title">{item.title}</span>
            {item.subtitle && (
              <span className="format-list__item-subtitle">{item.subtitle}</span>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}
