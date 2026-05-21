import { AgentResponse } from './Chat';
import { InAppCard } from './formats/InAppCard';
import { InAppList } from './formats/InAppList';
import { InAppButtonGroup } from './formats/InAppButtonGroup';
import { InAppForm } from './formats/InAppForm';
import { InAppCarousel } from './formats/InAppCarousel';

interface Props {
  response: AgentResponse;
  onButtonAction: (action: string, value: string) => void;
  onFormSubmit: (data: Record<string, string>) => void;
}

export function FormatRenderer({ response, onButtonAction, onFormSubmit }: Props) {
  const formatType = response.responseFormatType || response.type;

  switch (formatType) {
    case 'InAppCard':
      return <InAppCard data={response} onButtonAction={onButtonAction} />;
    case 'InAppList':
      return <InAppList data={response} onButtonAction={onButtonAction} />;
    case 'InAppButtonGroup':
      return <InAppButtonGroup data={response} onButtonAction={onButtonAction} />;
    case 'InAppForm':
      return <InAppForm data={response} onFormSubmit={onFormSubmit} />;
    case 'InAppCarousel':
      return <InAppCarousel data={response} onButtonAction={onButtonAction} />;
    case 'text':
      return <p className="format-text">{response.content as string}</p>;
    default:
      // Unknown format — render as plain text
      const text = (response as Record<string, unknown>).body
        || (response as Record<string, unknown>).content
        || JSON.stringify(response);
      return <p className="format-text">{String(text)}</p>;
  }
}
