import { createContext, useCallback, useContext, useEffect, useLayoutEffect, useSyncExternalStore } from 'react';
import { useLocation } from 'react-router-dom';
import { api } from './api';

type Snapshot = { data: unknown; error: Error | null; loading: boolean };
type Reader = (url: string, options: { signal: AbortSignal }) => Promise<unknown>;
class Resource {
  value: Snapshot;
  private controller = new AbortController();
  private pending = false;
  private listeners = new Set<() => void>();
  constructor(readonly revision: number, private url: string | null, private read: Reader) {
    this.value = { data: null, error: null, loading: Boolean(url) };
  }
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  snapshot = () => this.value;
  load() {
    if (!this.url || !this.value.loading || this.pending || this.controller.signal.aborted) return;
    this.pending = true;
    void this.read(this.url, { signal: this.controller.signal }).then(data => this.publish({ data, error: null, loading: false }))
      .catch(error => this.publish({ data: null, error: error instanceof Error ? error : new Error('请求未完成，请重试。'), loading: false }));
  }
  private publish(value: Snapshot) {
    if (this.controller.signal.aborted) return;
    this.value = value; this.listeners.forEach(listener => listener());
  }
  clear() { this.controller.abort(); this.listeners.clear(); }
}

/** Memory owned by the current account session and individual browser history entries. */
export class BrowsingSession {
  private resources = new Map<string, Resource>();
  private revisions = new Map<string, number>();
  private listeners = new Set<() => void>();
  private lifetime = 0;
  readonly scroll = new Map<string, number>();
  constructor(private read: Reader = api) {}
  attach() {
    const lifetime = ++this.lifetime;
    // React replays effect setup during development; only the final detach disposes the session.
    return () => queueMicrotask(() => { if (this.lifetime === lifetime) this.clear(); });
  }
  resource(entry: string, url: string | null, revision: number) {
    const key = JSON.stringify([entry, url]); let resource = this.resources.get(key);
    if (!resource || resource.revision !== revision) {
      resource?.clear(); resource = new Resource(revision, url, this.read); this.resources.set(key, resource);
    }
    return resource;
  }
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  revision(entry: string) { return this.revisions.get(entry) ?? 0; }
  refresh(entry: string, update: number | ((value: number) => number)) {
    this.revisions.set(entry, typeof update === 'function' ? update(this.revision(entry)) : update);
    this.scroll.set(entry, 0); this.listeners.forEach(listener => listener());
  }
  clear() {
    this.resources.forEach(resource => resource.clear()); this.resources.clear(); this.revisions.clear(); this.scroll.clear();
  }
}
export const BrowsingContext = createContext<BrowsingSession | null>(null);
function useSession() { const cache = useContext(BrowsingContext); if (!cache) throw new Error('Missing browsing session'); return cache; }
export function useBrowsingRefresh() {
  const cache = useSession(), { key } = useLocation();
  const refresh = useSyncExternalStore(cache.subscribe, () => cache.revision(key));
  const setRefresh = useCallback((update: number | ((value: number) => number)) => cache.refresh(key, update), [cache, key]);
  return [refresh, setRefresh] as const;
}
export function useBrowsingResource<T>(url: string | null, refresh = 0) {
  const cache = useSession(), { key } = useLocation();
  const resource = cache.resource(key, url, refresh);
  const value = useSyncExternalStore(resource.subscribe, resource.snapshot);
  useEffect(() => { resource.load(); }, [resource]);
  return value as { data: T | null; error: Error | null; loading: boolean };
}
export function BrowsingScroll() {
  const cache = useSession(), location = useLocation();
  const [refresh] = useBrowsingRefresh();
  useLayoutEffect(() => {
    if (location.pathname === '/following') return;
    const retained = location.pathname === '/search' || location.pathname.startsWith('/creator/');
    window.scrollTo({ top: retained ? cache.scroll.get(location.key) ?? 0 : 0, behavior: 'instant' });
    if (!retained) return;
    const remember = () => cache.scroll.set(location.key, Math.max(0, window.scrollY));
    window.addEventListener('scroll', remember, { passive: true });
    return () => window.removeEventListener('scroll', remember);
  }, [cache, location.key, location.pathname, refresh]);
  return null;
}
