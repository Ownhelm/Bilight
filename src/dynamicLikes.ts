import type { DynamicLikeState, VideoSummary } from '../shared/types';
import { api } from './api';
import { LikeStore } from './likeStore';

export class DynamicLikes extends LikeStore {
  constructor(write = (id: string, liked: boolean, signal: AbortSignal) => api<DynamicLikeState>(`/api/dynamics/${id}/like`, { method: 'POST', body: { liked }, signal, keepalive: true })) {
    super(write);
  }
  ingestVideos = (videos: VideoSummary[], version: number) => {
    for (const video of videos) if (video.dynamicId && typeof video.dynamicLiked === 'boolean' && typeof video.dynamicLikes === 'number') this.ingest(video.dynamicId, { liked: video.dynamicLiked, likes: video.dynamicLikes }, version);
  };
}
