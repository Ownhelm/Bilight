export interface WatchVideo extends EventTarget { readonly currentTime: number; readonly duration: number; readonly paused: boolean; readonly seeking: boolean; readonly playbackRate: number }

/** Only advancing playback counts as a watch; opening a page or seeking alone does not. */
export function observeWatchProgress(video: WatchVideo, record: (progress: number, completed: boolean) => void, now = Date.now) {
  let playing = !video.paused, watched = false, dirty = false, completed = false;
  let previous = video.currentTime, progress = previous, lastSent = -Infinity;
  const flush = (force = false) => {
    if (!watched || (!dirty && !force)) return;
    dirty = false; lastSent = now(); record(progress, completed);
  };
  const start = () => { playing = true; previous = video.currentTime; };
  const seek = () => { previous = video.currentTime; };
  const update = () => {
    const current = video.currentTime, advance = current - previous; previous = current;
    if (!playing || video.paused || video.seeking || !Number.isFinite(current) || advance <= 0 || advance > Math.max(5, 5 * video.playbackRate)) return;
    watched = true; progress = current; completed = false; dirty = true;
    if (now() - lastSent >= 15_000) flush();
  };
  const pause = () => { playing = false; flush(); };
  const end = () => {
    playing = false;
    if (!watched) return;
    if (Number.isFinite(video.duration) && video.duration > 0) progress = video.duration;
    completed = true; dirty = true; flush();
  };
  const listeners = { playing: start, timeupdate: update, seeking: seek, seeked: seek, pause, ended: end };
  for (const [event, listener] of Object.entries(listeners)) video.addEventListener(event, listener);
  return { flush, dispose() { flush(); for (const [event, listener] of Object.entries(listeners)) video.removeEventListener(event, listener); } };
}
