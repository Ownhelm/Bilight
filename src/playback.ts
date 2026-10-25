import type Artplayer from 'artplayer';
import type { Setting } from 'artplayer';
import type { Playback, Subtitle } from '../shared/types';

const settingText = (value: string) => value.replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]!);

const progressTime = (time: number) => {
  const seconds = Math.floor(time), minutes = Math.floor(seconds / 60);
  return `${minutes >= 60 ? `${Math.floor(minutes / 60)}:` : ''}${String(minutes % 60).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
};

/** Page-level seeking replaces the focus-only defaults, so each key moves exactly once. */
export function installProgressShortcuts(player: Pick<Artplayer, 'currentTime' | 'duration' | 'video' | 'hotkey' | 'notice'>, document: Document, switching = () => false): () => void {
  const previous = (['ArrowLeft', 'ArrowRight'] as const).map(key => ({ key, callbacks: [...(player.hotkey.keys[key] ?? [])] }));
  for (const { key, callbacks } of previous) for (const callback of callbacks) player.hotkey.remove(key, callback);
  const shortcut = (event: KeyboardEvent) => {
    if (!['ArrowLeft', 'ArrowRight'].includes(event.key) || event.defaultPrevented || event.isComposing || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return;
    const target = event.target as HTMLElement | null, active = document.activeElement as HTMLElement | null;
    const controls = 'input,textarea,select,[contenteditable]:not([contenteditable="false"]),[role="textbox"],[role="combobox"],[role="slider"],[role="spinbutton"],[role="listbox"],[role="tablist"],[role="menu"]';
    if ([target, active].some(element => element?.isContentEditable || element?.closest?.(controls)) || document.querySelector('dialog[open],[role="dialog"]')) return;
    const duration = player.duration;
    if (switching() || player.video.readyState < 1 || !Number.isFinite(duration) || duration <= 0 || !Number.isFinite(player.currentTime)) return;
    event.preventDefault();
    const delta = event.key === 'ArrowRight' ? 5 : -5, current = player.currentTime;
    const next = Math.min(duration, Math.max(0, current + delta));
    player.currentTime = next;
    const label = next === current ? next === 0 ? '已到视频开头' : '已到视频结尾' : `${delta > 0 ? '快进' : '后退'} ${Math.round(Math.abs(next - current) * 10) / 10} 秒`;
    player.notice.show = `${label} · ${progressTime(next)} / ${progressTime(duration)}`;
  };
  document.addEventListener('keydown', shortcut);
  return () => {
    document.removeEventListener('keydown', shortcut);
    for (const { key, callbacks } of previous) for (const callback of callbacks) player.hotkey.add(key, callback);
  };
}

export function qualitySetting(playback: Playback, onSelect: (id: number) => Promise<string>): Setting {
  return {
    name: 'quality', html: '清晰度', width: 220,
    tooltip: settingText(playback.qualities.find(item => item.id === playback.quality)?.label ?? ''),
    selector: playback.qualities.map(item => ({ name: `quality-${item.id}`, html: settingText(item.label), value: item.id, default: item.id === playback.quality })),
    onSelect: async item => settingText(await onSelect(Number(item.value))),
  };
}

export function defaultSubtitle(subtitles: Subtitle[]): string {
  const selected = subtitles.find(item => /^zh(?:-|$)/i.test(item.lang))
    ?? subtitles.find(item => /(?:^|-)zh(?:-|$)/i.test(item.lang))
    ?? subtitles[0];
  return selected?.id ?? '';
}

export interface PlaybackPosition { time: number; playing: boolean; rate: number }
export function playbackPosition(player: Artplayer): PlaybackPosition { return { time: player.currentTime, playing: player.playing, rate: player.playbackRate }; }
export function switchPlaybackSource(player: Artplayer, url: string, { signal, position, timeoutMs = 30_000 }: { signal: AbortSignal; position: PlaybackPosition; timeoutMs?: number }): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) { reject(new DOMException('已取消切换', 'AbortError')); return; }
    let finished = false;
    const cleanup = () => { clearTimeout(timer); signal.removeEventListener('abort', abort); player.off('video:loadedmetadata', metadata); player.off('video:canplay', canplay); player.off('video:error', failed); player.off('error', failed); };
    const finish = (error?: Error) => { if (finished) return; finished = true; cleanup(); error ? reject(error) : resolve(); };
    const abort = () => { player.pause(); finish(new DOMException('已取消切换', 'AbortError')); };
    const metadata = () => { player.currentTime = position.time; player.playbackRate = position.rate; };
    const canplay = () => {
      if (finished) return;
      player.off('video:canplay', canplay);
      player.playbackRate = position.rate;
      if (position.playing) void player.play().then(() => finish(), error => finish(error instanceof Error ? error : new Error('请手动点击播放以继续。')));
      else finish();
    };
    const failed = () => finish(new Error('视频流加载失败，请切换清晰度或重试。'));
    const timer = setTimeout(() => finish(new Error('视频流加载超时，请切换清晰度或重试。')), timeoutMs);
    signal.addEventListener('abort', abort, { once: true });
    player.on('video:loadedmetadata', metadata); player.on('video:canplay', canplay); player.on('video:error', failed); player.on('error', failed);
    try { player.pause(); player.url = url; } catch (error) { finish(error instanceof Error ? error : new Error('暂时无法切换视频流。')); }
  });
}
