import { useCallback, useEffect, useRef, useState } from 'react';
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

export function useFollowingFeed(enabled: boolean) {
  const [state, setState] = useState<FeedState>(emptyFeed);
  const active = useRef<AbortController | null>(null);
  const visited = useRef(new Set<string>());
  const lastRequest = useRef({ cursor: '', replace: true });
  const load = useCallback(async (cursor: string, replace: boolean) => {
    if (active.current) return;
    const controller = new AbortController(); active.current = controller;
    lastRequest.current = { cursor, replace };
    setState(current => ({ ...current, loading: true, error: null }));
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, 30_000);
    try {
      const page = await api<Page<VideoSummary>>(`/api/following${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ''}`, { signal: controller.signal });
      if (controller.signal.aborted || active.current !== controller) return;
      if (replace) visited.current.clear();
      visited.current.add(cursor);
      const next = nextFollowingCursor(page, visited.current);
      setState(current => ({ items: mergeFollowing(replace ? [] : current.items, page.items), cursor: next, loading: false, initialized: true, error: null }));
    } catch (error) {
      if (active.current !== controller || (isAbort(error) && !timedOut)) return;
      const failure = timedOut ? new Error('B 站响应较慢，请重试。已加载的视频会保留。') : error instanceof Error ? error : new Error(errorMessage(error));
      setState(current => ({ ...current, loading: false, initialized: true, error: failure }));
    } finally {
      clearTimeout(timer);
      if (active.current === controller) { active.current = null; setState(current => ({ ...current, loading: false })); }
    }
  }, []);
  useEffect(() => {
    setState(emptyFeed); visited.current.clear();
    if (enabled) void load('', true);
    return () => { active.current?.abort(); active.current = null; };
  }, [enabled, load]);
  const loadMore = useCallback(() => { if (state.cursor && !state.error) void load(state.cursor, false); }, [state.cursor, state.error, load]);
  const refresh = useCallback(() => { if (enabled) void load('', true); }, [enabled, load]);
  const retry = useCallback(() => { if (enabled) void load(lastRequest.current.cursor, lastRequest.current.replace); }, [enabled, load]);
  return { ...state, loadMore, refresh, retry };
}
