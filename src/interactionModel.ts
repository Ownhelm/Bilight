import type { FavoriteFolder, VideoEngagement, VideoInteraction } from '../shared/types';

export function coinChoices(limit: number, given: number): (1 | 2)[] {
  return ([1, 2] as const).filter(value => value <= Math.max(0, limit - given));
}
export function favoriteChanged(folders: FavoriteFolder[], ids: number[]): boolean {
  const selected = new Set(ids);
  return folders.some(folder => folder.selected !== selected.has(folder.id));
}
export function engagementCounts(snapshot?: VideoInteraction, baseline?: VideoEngagement | null, state?: VideoEngagement | null) {
  if (!snapshot) return null;
  return {
    likes: Math.max(0, snapshot.likes + (baseline && state ? Number(state.liked) - Number(baseline.liked) : 0)),
    coins: Math.max(0, snapshot.coins + (baseline && state ? state.coins - baseline.coins : 0)),
    favorites: Math.max(0, snapshot.favorites + (baseline && state ? Number(state.favorited) - Number(baseline.favorited) : 0)),
  };
}
