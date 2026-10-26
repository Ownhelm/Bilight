import { useEffect, useState, useSyncExternalStore } from 'react';
import type { Page, VideoSummary } from '../shared/types';
import { api, errorMessage, isAbort } from './api';

export function mergeFollowing(current: VideoSummary[], incoming: VideoSummary[]): VideoSummary[] {
  const videos = new Map(current.map(video => [video.bvid, video]));
  for (const video of incoming) videos.set(video.bvid, video);
  return [...videos.values()].sort((a, b) => b.publishedAt - a.publishedAt || a.bvid.localeCompare(b.bvid));
}

export function nextFollowingCursor(page: Page<VideoSummary>, visited: ReadonlySet<string>): string | null {
  return page.hasMore && page.nextCursor && !visited.has(page.nextCursor) ? page.nextCursor : null;
}

export function followingColumns(width: number): number { return width <= 640 ? 2 : width <= 1100 ? 3 : 4; }
export function completeFollowingRows(items: VideoSummary[], columns: number, hasMore: boolean): VideoSummary[] {
  return hasMore ? items.slice(0, Math.floor(items.length / columns) * columns) : items;
}
export function useFollowingColumns(): number {
  const [columns, setColumns] = useState(() => followingColumns(window.innerWidth));
  useEffect(() => {
    // Match the existing video-grid CSS breakpoints without running a handler on every resize pixel.
    const queries = [window.matchMedia('(max-width: 640px)'), window.matchMedia('(max-width: 1100px)')];
    const update = () => setColumns(followingColumns(window.innerWidth));
    queries.forEach(query => query.addEventListener('change', update));
    return () => queries.forEach(query => query.removeEventListener('change', update));
  }, []);
  return columns;
}

interface FeedState { items: VideoSummary[]; cursor: string | null; loading: boolean; initialized: boolean; error: Error | null }
const emptyFeed: FeedState = { items: [], cursor: null, loading: false, initialized: false, error: null };

export class FollowingFeed {
  private state = emptyFeed;
  private active: AbortController | null = null;
  private visited = new Set<string>();
  private lastRequest = { cursor: '', replace: true };
  private listeners = new Set<() => void>();
  scrollTop = 0;
  constructor(private readPage = (cursor: string, signal: AbortSignal) => api<Page<VideoSummary>>(`/api/following${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ''}`, { signal })) {}
  getSnapshot = () => this.state;
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  private publish(state: FeedState) { this.state = state; this.listeners.forEach(listener => listener()); }
  ensureLoaded = () => { if (!this.state.initialized) return this.load('', true); };
  loadMore = () => { if (this.state.cursor && !this.state.error) return this.load(this.state.cursor, false); };
  refresh = () => this.load('', true);
  retry = () => this.load(this.lastRequest.cursor, this.lastRequest.replace);
  clear = () => {
    this.active?.abort(); this.active = null;
    this.visited.clear(); this.lastRequest = { cursor: '', replace: true }; this.scrollTop = 0;
    this.publish(emptyFeed);
  };
  private async load(cursor: string, replace: boolean) {
    if (this.active) return;
    const controller = new AbortController(); this.active = controller;
    this.lastRequest = { cursor, replace };
    this.publish({ ...this.state, loading: true, error: null });
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, 30_000);
    try {
      const page = await this.readPage(cursor, controller.signal);
      if (controller.signal.aborted || this.active !== controller) return;
      if (replace) this.visited.clear();
      this.visited.add(cursor);
      const next = nextFollowingCursor(page, this.visited);
      this.publish({ items: mergeFollowing(replace ? [] : this.state.items, page.items), cursor: next, loading: false, initialized: true, error: null });
    } catch (error) {
      if (this.active !== controller || (isAbort(error) && !timedOut)) return;
      const failure = timedOut ? new Error('B 站响应较慢，请重试。已加载的视频会保留。') : error instanceof Error ? error : new Error(errorMessage(error));
      this.publish({ ...this.state, loading: false, initialized: true, error: failure });
    } finally {
      clearTimeout(timer);
      if (this.active === controller) this.active = null;
    }
  }
}

export function useFollowingFeed(cache: FollowingFeed, enabled: boolean) {
  const state = useSyncExternalStore(cache.subscribe, cache.getSnapshot);
  useEffect(() => {
    if (enabled) void cache.ensureLoaded();
    else cache.clear();
    // Route changes only unsubscribe; the account-owned request/cache survives navigation.
  }, [enabled, cache]);
  return { ...state, loadMore: cache.loadMore, refresh: cache.refresh, retry: cache.retry };
}
