import type { DynamicLikeState, VideoDynamic, VideoSummary } from '../shared/types';
import { api } from './api';

type LikeSnapshot = { states: Record<string, DynamicLikeState>; pending: Record<string, boolean> };
export class DynamicLikes {
  private snapshot: LikeSnapshot = { states: {}, pending: {} };
  private revision = 0;
  private stamps = new Map<string, number>();
  private active = new Map<string, { controller: AbortController; request: Promise<void> }>();
  private listeners = new Set<() => void>();
  constructor(private write = (id: string, liked: boolean, signal: AbortSignal) => api<VideoDynamic>(`/api/dynamics/${id}/like`, { method: 'POST', body: { liked }, signal })) {}
  getSnapshot = () => this.snapshot;
  readVersion = () => this.revision;
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  private publish(value: LikeSnapshot) { this.snapshot = value; this.listeners.forEach(listener => listener()); }
  ingest(id: string, state: DynamicLikeState, version: number) {
    if (this.active.has(id) || (this.stamps.get(id) ?? 0) > version) return;
    this.publish({ ...this.snapshot, states: { ...this.snapshot.states, [id]: state } });
  }
  ingestVideos = (videos: VideoSummary[], version: number) => {
    for (const video of videos) if (video.dynamicId && typeof video.dynamicLiked === 'boolean' && typeof video.dynamicLikes === 'number') this.ingest(video.dynamicId, { liked: video.dynamicLiked, likes: video.dynamicLikes }, version);
  };
  toggle(id: string, initial: DynamicLikeState): Promise<void> {
    const active = this.active.get(id); if (active) return active.request;
    const before = this.snapshot.states[id] ?? initial, target = !before.liked, controller = new AbortController();
    this.stamps.set(id, ++this.revision);
    const request = Promise.resolve().then(async () => {
      try {
        const after = await this.write(id, target, controller.signal);
        if (controller.signal.aborted) return;
        this.stamps.set(id, ++this.revision);
        this.publish({ ...this.snapshot, states: { ...this.snapshot.states, [id]: { liked: after.liked, likes: after.likes } } });
      } finally {
        if (this.active.get(id)?.controller === controller) {
          this.active.delete(id); const pending = { ...this.snapshot.pending }; delete pending[id];
          this.publish({ ...this.snapshot, pending });
        }
      }
    });
    this.active.set(id, { controller, request });
    this.publish({ states: { ...this.snapshot.states, [id]: before }, pending: { ...this.snapshot.pending, [id]: target } });
    return request;
  }
  clear = () => {
    for (const active of this.active.values()) active.controller.abort();
    this.active.clear(); this.stamps.clear(); this.revision++;
    this.publish({ states: {}, pending: {} });
  };
}
