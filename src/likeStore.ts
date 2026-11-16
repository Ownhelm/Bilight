import type { DynamicLikeState as LikeState } from '../shared/types';
import { ApiError, errorMessage, isAbort } from './api';

const SYNC_DELAY = 800;
type LikeSnapshot = {
  states: Record<string, LikeState>;
  pending: Partial<Record<string, LikeState>>;
  errors: Partial<Record<string, string>>;
};
type Change = { timer?: ReturnType<typeof setTimeout>; controller?: AbortController };

export class LikeStore {
  private snapshot: LikeSnapshot = { states: {}, pending: {}, errors: {} };
  private revision = 0;
  private stamps = new Map<string, number>();
  private changes = new Map<string, Change>();
  private uncertain = new Set<string>();
  private listeners = new Set<() => void>();
  constructor(private write: (id: string, liked: boolean, signal: AbortSignal) => Promise<LikeState>) {}
  getSnapshot = () => this.snapshot;
  readVersion = () => this.revision;
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  private publish(value: LikeSnapshot) { this.snapshot = value; this.listeners.forEach(listener => listener()); }
  ingest(id: string, state: LikeState, version: number) {
    if (this.changes.has(id) || (this.stamps.get(id) ?? 0) > version) return;
    this.publish({ ...this.snapshot, states: { ...this.snapshot.states, [id]: state } });
  }

  toggle(id: string, initial: LikeState) {
    const confirmed = this.snapshot.states[id] ?? initial;
    const visible = this.snapshot.pending[id] ?? confirmed;
    const liked = !visible.liked;
    const change = this.changes.get(id) ?? {};
    this.changes.set(id, change);
    this.stamps.set(id, ++this.revision);
    clearTimeout(change.timer);
    change.timer = setTimeout(() => {
      change.timer = undefined;
      void this.sync(id, change);
    }, SYNC_DELAY);
    const errors = { ...this.snapshot.errors };
    delete errors[id];
    this.publish({
      states: { ...this.snapshot.states, [id]: confirmed },
      pending: { ...this.snapshot.pending, [id]: { liked, likes: Math.max(0, visible.likes + (liked ? 1 : -1)) } },
      errors,
    });
  }

  private async sync(id: string, change: Change) {
    if (change.controller || this.changes.get(id) !== change) return;
    const target = this.snapshot.pending[id];
    if (!target) return;
    const before = this.snapshot.states[id];
    if (target.liked === before.liked && !this.uncertain.has(id)) {
      this.finish(id, change, before);
      return;
    }

    const controller = new AbortController();
    change.controller = controller;
    try {
      // The endpoint reads the current Bilibili state before setting the explicit target.
      const result = await this.write(id, target.liked, controller.signal);
      if (this.changes.get(id) !== change) return;
      this.uncertain.delete(id);
      const confirmed = { liked: result.liked, likes: result.likes };
      const latest = this.snapshot.pending[id]?.liked;
      if (latest === confirmed.liked || latest === target.liked) {
        this.finish(id, change, confirmed);
        return;
      }
      // Keep the latest optimistic count on screen until its own target settles.
      this.publish({ ...this.snapshot, states: { ...this.snapshot.states, [id]: confirmed } });
    } catch (error) {
      if (this.changes.get(id) !== change) return;
      if (!(error instanceof ApiError) || error.status === 0 || error.status >= 500 || ['INTERACTION_BUSY', 'COMMENT_BUSY'].includes(error.code)) this.uncertain.add(id);
      if (this.snapshot.pending[id]?.liked === target.liked) {
        this.finish(id, change, before, isAbort(error) ? undefined : errorMessage(error));
        return;
      }
    }
    change.controller = undefined;
    if (!change.timer) void this.sync(id, change);
  }

  private finish(id: string, change: Change, state: LikeState, error?: string) {
    clearTimeout(change.timer);
    this.changes.delete(id);
    this.stamps.set(id, ++this.revision);
    const pending = { ...this.snapshot.pending }, errors = { ...this.snapshot.errors };
    delete pending[id];
    if (error) errors[id] = error;
    this.publish({ states: { ...this.snapshot.states, [id]: state }, pending, errors });
  }

  clear = () => {
    for (const change of this.changes.values()) {
      clearTimeout(change.timer);
      change.controller?.abort();
    }
    this.changes.clear(); this.uncertain.clear(); this.stamps.clear(); this.revision++;
    this.publish({ states: {}, pending: {}, errors: {} });
  };
}
