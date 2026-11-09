import { isVideoSearchOrder, type VideoSearchOrder, type VideoSummary } from '../shared/types';

export type SearchPreferences = { order: VideoSearchOrder; titleOnly: boolean };
const key = 'bilight:video-search';

export function readSearchPreferences(): SearchPreferences {
  try {
    const stored = JSON.parse(localStorage.getItem(key) ?? 'null');
    return { order: isVideoSearchOrder(stored?.order) ? stored.order : 'totalrank', titleOnly: stored?.titleOnly === true };
  } catch { return { order: 'totalrank', titleOnly: false }; }
}

export function saveSearchPreferences({ order, titleOnly }: SearchPreferences) {
  try { localStorage.setItem(key, JSON.stringify({ order, titleOnly })); }
  catch { /* Filters still work while this page is open. */ }
}

export function matchingSearchTitles(videos: VideoSummary[], keyword: string) {
  const normalize = (value: string) => value.normalize('NFKC').toLowerCase();
  const terms = normalize(keyword).trim().split(/\s+/);
  return videos.filter(video => {
    const title = normalize(video.title);
    return terms.every(term => title.includes(term));
  });
}
