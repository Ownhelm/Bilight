import { useEffect, useId, useRef, useState } from 'react';
import { CaretDown, Check, SlidersHorizontal } from '@phosphor-icons/react';
import type { VideoSearchOrder } from '../shared/types';
import type { SearchPreferences } from './searchPreferences';
import './searchFilters.css';

const orderLabels: Record<VideoSearchOrder, string> = { totalrank: '综合', pubdate: '最新', click: '播放多' };
const orders = Object.keys(orderLabels) as VideoSearchOrder[];
export const titleFilterLabel = '仅标题匹配';

export function SearchFilters({ value, onChange }: { value: SearchPreferences; onChange: (value: SearchPreferences) => void }) {
  const [open, setOpen] = useState(false);
  const container = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const selectedOrder = useRef<HTMLButtonElement>(null);
  const panelId = useId();
  const descriptionId = `${panelId}-title-description`;
  const active = value.titleOnly || value.order !== 'totalrank';
  const label = value.titleOnly ? titleFilterLabel : active ? orderLabels[value.order] : '筛选';
  function closeAndFocus() {
    setOpen(false);
    trigger.current?.focus({ preventScroll: true });
  }
  useEffect(() => {
    if (!open) return;
    selectedOrder.current?.focus({ preventScroll: true });
    function dismiss(event: PointerEvent) {
      if (!container.current?.contains(event.target as Node)) setOpen(false);
    }
    document.addEventListener('pointerdown', dismiss);
    return () => document.removeEventListener('pointerdown', dismiss);
  }, [open]);

  return <div className="video-search-filter" ref={container}
    onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false); }}
    onKeyDown={event => { if (open && event.key === 'Escape') { event.preventDefault(); closeAndFocus(); } }}>
    <button type="button" ref={trigger} className={`video-search-filter-trigger${active ? ' active' : ''}`}
      aria-label={`搜索筛选，${orderLabels[value.order]}${value.titleOnly ? `，${titleFilterLabel}` : ''}`}
      aria-expanded={open} aria-controls={open ? panelId : undefined} onClick={() => setOpen(!open)}>
      <SlidersHorizontal size={18} aria-hidden="true" /><span>{label}</span><CaretDown size={12} aria-hidden="true" />
    </button>
    {open && <div className="video-search-filter-panel" id={panelId} role="group" aria-label="视频搜索选项">
      <div role="group" aria-label="视频排序">
        {orders.map(order => <button type="button" key={order} aria-pressed={value.order === order}
          ref={value.order === order ? selectedOrder : undefined} onClick={() => { onChange({ ...value, order }); closeAndFocus(); }}>
          {orderLabels[order]}{value.order === order && <Check size={16} className="search-order-check" aria-hidden="true" />}
        </button>)}
      </div>
      <div className="video-search-filter-divider" />
      <button type="button" className="search-title-filter-option" aria-label={titleFilterLabel} aria-describedby={descriptionId}
        aria-pressed={value.titleOnly} onClick={() => { onChange({ ...value, titleOnly: !value.titleOnly }); closeAndFocus(); }}>
        <span className="search-title-filter-label">
          {titleFilterLabel}{value.titleOnly && <Check size={16} className="search-title-check" aria-hidden="true" />}
        </span>
        <span className="search-title-filter-description" id={descriptionId}>只保留标题包含所有搜索词的视频</span>
      </button>
    </div>}
  </div>;
}
