import { useRef } from 'react';
import './formats.css';

interface CarouselCard {
  id: string;
  title: string;
  description?: string;
  imageUrl: string;
  badge?: string;
  buttons: { id: string; label: string; action: 'link' | 'reply' | 'submit'; value: string }[];
}

interface Props {
  data: {
    title?: string;
    cards?: CarouselCard[];
    [key: string]: unknown;
  };
  onButtonAction: (action: string, value: string) => void;
}

export function InAppCarousel({ data, onButtonAction }: Props) {
  const cards = data.cards || [];
  const scrollRef = useRef<HTMLDivElement>(null);

  function scrollLeft() {
    scrollRef.current?.scrollBy({ left: -280, behavior: 'smooth' });
  }

  function scrollRight() {
    scrollRef.current?.scrollBy({ left: 280, behavior: 'smooth' });
  }

  return (
    <div className="format-carousel" aria-label={data.title || 'Carousel'}>
      {data.title && <h3 className="format-carousel__title">{data.title}</h3>}

      <div className="format-carousel__wrapper">
        <button
          className="format-carousel__nav format-carousel__nav--left"
          onClick={scrollLeft}
          aria-label="Scroll left"
        >
          &#8249;
        </button>

        <div className="format-carousel__track" ref={scrollRef} role="list">
          {cards.map(card => (
            <div key={card.id} className="format-carousel__card" role="listitem">
              <div className="format-carousel__img-wrapper">
                <img className="format-carousel__image" src={card.imageUrl} alt="" />
                {card.badge && (
                  <span className="format-carousel__badge">{card.badge}</span>
                )}
              </div>
              <div className="format-carousel__card-content">
                <h4 className="format-carousel__card-title">{card.title}</h4>
                {card.description && (
                  <p className="format-carousel__card-desc">{card.description}</p>
                )}
              </div>
              <div className="format-carousel__card-actions">
                {card.buttons.map(btn => (
                  <button
                    key={btn.id}
                    className="format-btn format-btn--small"
                    onClick={() => onButtonAction(btn.action, btn.value)}
                    aria-label={btn.label}
                  >
                    {btn.label}
                  </button>
                ))}
              </div>
            </div>
          ))}
        </div>

        <button
          className="format-carousel__nav format-carousel__nav--right"
          onClick={scrollRight}
          aria-label="Scroll right"
        >
          &#8250;
        </button>
      </div>
    </div>
  );
}
