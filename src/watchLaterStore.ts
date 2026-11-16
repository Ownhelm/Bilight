import type { WatchLaterItem, WatchLaterPage } from '../shared/types';
import { api } from './api';

type Membership = { accountMid: number; aids: number[] };
type Mutation = { accountMid: number; saved: boolean };
type Removal = { accountMid: number; removed: number[] };
type List = { items: WatchLaterItem[]; total: number; nextPage?: number };
type Snapshot = {
  aids: ReadonlySet<number>;
  pending: ReadonlySet<number>;
  list: List | null;
  listLoading: boolean;
  listError: unknown;
};

export class WatchLaterStore {
  private lifetime = 0;
  private controller = new AbortController();
  private listeners = new Set<() => void>();
  private state: Snapshot = { aids: new Set(), pending: new Set(), list: null, listLoading: false, listError: null };
  private version = 0;
  private known = false;
  private dirty = false;
  private loadedPages = 1;
  private failedAppend = false;
  private membershipRequest: Promise<void> | null = null;
  private listRequest: Promise<void> | null = null;

  constructor(readonly accountMid?: number, private request = api) {}

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  };
  snapshot = () => this.state;

  attach() {
    const lifetime = ++this.lifetime;
    return () => queueMicrotask(() => {
      if (this.lifetime === lifetime) this.controller.abort();
    });
  }

  private publish(change: Partial<Snapshot>) {
    if (this.controller.signal.aborted) return;
    this.state = { ...this.state, ...change };
    this.listeners.forEach(listener => listener());
  }

  private assertAccount(result: { accountMid: number }) {
    if (this.controller.signal.aborted) throw new DOMException('请求已取消。', 'AbortError');
    if (result.accountMid !== this.accountMid) throw new Error('B 站账号已切换，请刷新后重试。');
  }

  async refreshMembership(force = false): Promise<void> {
    if (!this.accountMid || (!force && this.known)) return;
    if (this.membershipRequest) return this.membershipRequest;
    const version = this.version;
    this.membershipRequest = this.request<Membership>(`/api/watch-later/membership?accountMid=${this.accountMid}&refresh=1`, { signal: this.controller.signal })
      .then(result => {
        this.assertAccount(result);
        if (version !== this.version) return;
        this.known = true;
        this.publish({ aids: new Set(result.aids) });
      }).finally(() => { this.membershipRequest = null; });
    return this.membershipRequest;
  }

  loadList(append = false): Promise<void> {
    if (!this.accountMid) return Promise.resolve();
    if (this.listRequest) return this.listRequest;
    const previous = this.state.list;
    if (append && !previous?.nextPage) return Promise.resolve();
    const version = this.version;
    const keep = append && !this.dirty;
    const pages = append ? this.loadedPages + 1 : this.loadedPages;
    let stale = false;
    this.publish({ listLoading: true, listError: null });
    this.listRequest = (async () => {
      const items = new Map(keep ? previous?.items.map(item => [item.aid, item] as const) : undefined);
      let nextPage: number | undefined = keep ? previous?.nextPage : 1;
      let loadedPages = keep ? this.loadedPages : 0;
      let total = previous?.total ?? 0;
      while (nextPage && loadedPages < pages) {
        const data: WatchLaterPage = await this.request<WatchLaterPage>(`/api/watch-later?page=${nextPage}&accountMid=${this.accountMid}`, { signal: this.controller.signal });
        this.assertAccount(data);
        if (version !== this.version) { stale = true; return; }
        data.items.forEach(item => items.set(item.aid, item));
        loadedPages += 1;
        total = data.total;
        nextPage = data.hasMore ? data.nextPage ?? nextPage + 1 : undefined;
      }
      this.dirty = false;
      this.loadedPages = loadedPages;
      const aids = new Set([...this.state.aids, ...items.keys()]);
      this.publish({ list: { items: [...items.values()], total, nextPage }, aids });
    })().catch(error => {
      if (version !== this.version) stale = true;
      else { this.failedAppend = append; this.publish({ listError: error }); }
    }).finally(() => {
      this.listRequest = null;
      this.publish({ listLoading: false });
      if (stale && !this.controller.signal.aborted) return this.loadList(append);
    });
    return this.listRequest;
  }

  retryList = () => this.loadList(this.failedAppend);

  private lock(aids: number[]) {
    const pending = new Set(this.state.pending);
    aids.forEach(aid => pending.add(aid));
    this.publish({ pending });
    return () => {
      const pending = new Set(this.state.pending);
      aids.forEach(aid => pending.delete(aid));
      this.publish({ pending });
    };
  }

  async set(aid: number, saved: boolean): Promise<boolean | undefined> {
    if (!this.accountMid || this.state.pending.has(aid)) return;
    const unlock = this.lock([aid]);
    let writing = false;
    try {
      if (!this.known) {
        await this.refreshMembership();
        if (!this.known) await this.refreshMembership();
        if (!this.known) throw new Error('稍后再看状态暂时无法确认，请重试。');
      }
      const wasSaved = this.state.aids.has(aid);
      this.version += 1;
      writing = true;
      const result = await this.request<Mutation>(`/api/watch-later/${aid}`, {
        method: 'PUT', body: { accountMid: this.accountMid, saved }, signal: this.controller.signal,
      });
      this.assertAccount(result);
      if (result.saved !== saved) throw new Error('稍后再看状态暂时无法确认，请刷新后重试。');
      if (saved) {
        this.dirty = true;
        const list = this.state.list;
        this.publish({ aids: new Set([...this.state.aids, aid]), list: list && { ...list, total: list.total + (wasSaved ? 0 : 1) } });
      } else this.applyRemoval([aid]);
      return result.saved;
    } catch (error) {
      if (writing) { this.known = false; this.dirty = true; }
      throw error;
    } finally {
      if (writing) this.version += 1;
      unlock();
    }
  }

  async remove(aids: number[]): Promise<number[]> {
    if (!this.accountMid || !aids.length || aids.some(aid => this.state.pending.has(aid))) return [];
    const unlock = this.lock(aids);
    this.version += 1;
    try {
      const result = await this.request<Removal>('/api/watch-later', {
        method: 'DELETE', body: { accountMid: this.accountMid, aids }, signal: this.controller.signal,
      });
      this.assertAccount(result);
      const removed = new Set(result.removed);
      const accepted = aids.filter(aid => removed.has(aid));
      this.applyRemoval(accepted);
      return accepted;
    } catch (error) {
      this.known = false;
      this.dirty = true;
      throw error;
    } finally {
      this.version += 1;
      unlock();
    }
  }

  private applyRemoval(ids: number[]) {
    const removed = new Set(ids);
    const aids = new Set([...this.state.aids].filter(aid => !removed.has(aid)));
    const list = this.state.list;
    this.dirty = true;
    this.publish({ aids, list: list && {
      ...list,
      total: Math.max(0, list.total - list.items.filter(item => removed.has(item.aid)).length),
      items: list.items.filter(item => !removed.has(item.aid)),
    } });
  }
}
