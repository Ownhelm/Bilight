import type { HistoryItem } from '../shared/types';

export function historyHref(item: HistoryItem): string {
  const params = new URLSearchParams({ p: String(item.page) });
  if (item.progress > 0 && (!item.duration || item.progress < item.duration)) params.set('t', String(Math.floor(item.progress)));
  return `/video/${item.bvid}?${params}`;
}

export function historyDay(timestamp: number, now = new Date()): string {
  const today = new Date(now); today.setHours(0, 0, 0, 0);
  const yesterday = new Date(today); yesterday.setDate(yesterday.getDate() - 1);
  const time = timestamp * 1000;
  return time >= today.getTime() ? '今天' : time >= yesterday.getTime() ? '昨天' : new Date(time).toLocaleDateString('zh-CN', { year: 'numeric', month: 'long', day: 'numeric' });
}
