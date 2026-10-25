import { useEffect, useRef, useState } from 'react';
import type Artplayer from 'artplayer';
import type { Result as DanmakuPlugin, Danmu } from 'artplayer-plugin-danmuku';
import type { MediaPlayerClass } from 'dashjs';
import { ChatCircleDots, SpinnerGap } from '@phosphor-icons/react';
import type { Danmaku, Playback, WatchProgress } from '../shared/types';
import { api, errorMessage, isAbort } from './api';
import { Failure, Loading, useResource } from './components';
import { defaultSubtitle, installProgressShortcuts, playbackPosition, qualitySetting, switchPlaybackSource, type PlaybackPosition } from './playback';
import { observeWatchProgress } from './watchHistory';

export function VideoPlayer({ bvid, cid, poster, startTime = 0, accountMid }: { bvid: string; cid: number; poster: string; startTime?: number; accountMid?: number }) {
  const [quality, setQuality] = useState<number | undefined>();
  const [selectedPlayback, setSelectedPlayback] = useState<Playback | null>(null);
  const [qualityBusy, setQualityBusy] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [speed, setSpeed] = useState(1);
  const [subtitle, setSubtitle] = useState<string | null>(null);
  const [danmaku, setDanmaku] = useState(false);
  const [danmakuBusy, setDanmakuBusy] = useState(false);
  const [playerError, setPlayerError] = useState('');
  const [historyError, setHistoryError] = useState('');
  const retryHistory = useRef<(() => void) | null>(null);
  const [ready, setReady] = useState(false);
  const [created, setCreated] = useState(false);
  const mount = useRef<HTMLDivElement>(null);
  const playerRef = useRef<Artplayer | null>(null);
  const switchPlayback = useRef<((next: Playback, signal: AbortSignal, position: PlaybackPosition) => Promise<void>) | null>(null);
  const resumePosition = useRef<PlaybackPosition | null>(null);
  const qualityRequest = useRef<AbortController | null>(null);
  const selectQuality = useRef<(id: number) => Promise<string>>(async () => '');
  const offset = useRef(startTime);
  useEffect(() => { offset.current = startTime; if (playerRef.current?.isReady) playerRef.current.currentTime = startTime; }, [startTime]);
  const initial = useResource<Playback>(`/api/videos/${bvid}/playback?cid=${cid}`, refresh);
  const { error, loading } = initial;
  const data = selectedPlayback ?? initial.data;
  const subtitleId = subtitle ?? defaultSubtitle(data?.subtitles ?? []);
  const wantedSubtitle = useRef(subtitleId); wantedSubtitle.current = subtitleId;
  selectQuality.current = async nextQuality => {
    const label = () => data?.qualities.find(item => item.id === data.quality)?.label ?? '';
    const player = playerRef.current;
    if (!data || !player || !created || (!qualityRequest.current && nextQuality === data.quality)) return label();
    qualityRequest.current?.abort();
    const controller = new AbortController(); qualityRequest.current = controller;
    setQuality(nextQuality); setQualityBusy(true); setPlayerError('');
    try {
      const next = await api<Playback>(`/api/videos/${bvid}/playback?cid=${cid}&quality=${nextQuality}`, { signal: AbortSignal.any([controller.signal, AbortSignal.timeout(30_000)]) });
      if (controller.signal.aborted || playerRef.current !== player || !switchPlayback.current) return label();
      // Keep the same video element so fullscreen, position, speed and pause state survive.
      resumePosition.current ??= playbackPosition(player);
      setReady(false);
      await switchPlayback.current(next, controller.signal, resumePosition.current);
      if (controller.signal.aborted || playerRef.current !== player) return label();
      setSelectedPlayback(next); setQuality(next.quality); setReady(true);
      resumePosition.current = null;
      return next.qualities.find(item => item.id === next.quality)?.label ?? '';
    } catch (error) {
      if (!controller.signal.aborted) {
        setPlayerError(`清晰度切换失败：${errorMessage(error)}`);
        setQuality(data.quality);
        setReady(player.video.readyState >= 3);
        if (player.video.readyState >= 3) resumePosition.current = null;
      }
      return label();
    } finally {
      if (qualityRequest.current === controller) { qualityRequest.current = null; setQualityBusy(false); }
    }
  };
  useEffect(() => {
    const source = initial.data;
    setReady(false); setCreated(false);
    setSelectedPlayback(null); setQuality(undefined);
    if (!source || !mount.current) return;
    let cancelled = false; let player: Artplayer | undefined; let dash: MediaPlayerClass | undefined; let removeProgressShortcuts: (() => void) | undefined;
    setPlayerError(''); setReady(false);
    async function create() {
      try {
        const [{ default: Artplayer }, dashModule] = await Promise.all([import('artplayer'), source!.manifestUrl ? import('dashjs') : Promise.resolve(null)]);
        let dashjs = dashModule;
        if (cancelled || !mount.current) return;
        const url = source!.manifestUrl || source!.mp4Url;
        if (!url) throw new Error('这个视频暂时没有可用的播放地址。');
        Artplayer.LOG_VERSION = false;
        player = new Artplayer({ container: mount.current, url, poster, type: source!.manifestUrl ? 'mpd' : 'mp4',
          theme: '#e95283', lang: 'zh-cn', autoplay: false, autoPlayback: false, autoMini: false, loop: false,
          fullscreen: true, fullscreenWeb: true, hotkey: true, pip: true, playbackRate: true, setting: true,
          settings: [qualitySetting(source!, id => selectQuality.current(id))],
          screenshot: false, moreVideoAttr: { playsInline: true, preload: 'metadata' },
          customType: { mpd(video, source) {
            if (!dashjs) return;
            if (!window.MediaSource && !('ManagedMediaSource' in window)) { setPlayerError('当前浏览器不支持这个视频的 DASH 播放，请尝试更新浏览器或使用 Chrome。'); return; }
            dash?.reset();
            dash = dashjs.MediaPlayer().create();
            dash.updateSettings({ debug: { logLevel: 0 }, streaming: { abr: { autoSwitchBitrate: { video: false } }, scheduling: { scheduleWhilePaused: true }, buffer: { initialBufferLevel: 1, bufferTimeDefault: 8, bufferTimeAtTopQuality: 12, bufferTimeAtTopQualityLongForm: 16, bufferToKeep: 8 } } });
            dash.initialize(video, source, false);
            dash.on('error', () => { if (!cancelled) setPlayerError('视频流暂时无法加载，请重试或切换清晰度。'); });
          }, mp4(video, source) { dash?.reset(); dash = undefined; video.src = source; } },
        });
        playerRef.current = player;
        removeProgressShortcuts = installProgressShortcuts(player, document, () => Boolean(qualityRequest.current && resumePosition.current));
        switchPlayback.current = async (next, signal, position) => {
          if (!player) return;
          const url = next.manifestUrl || next.mp4Url;
          if (!url) throw new Error('这个清晰度暂时没有可用的播放地址。');
          if (next.manifestUrl && !dashjs) dashjs = await import('dashjs');
          if (cancelled || signal.aborted) throw new DOMException('已取消切换', 'AbortError');
          player.type = next.manifestUrl ? 'mpd' : 'mp4';
          await switchPlaybackSource(player, url, { signal, position });
        };
        player.on('ready', () => {
          if (cancelled || !player) return;
          if (offset.current > 0) player.currentTime = offset.current;
          setReady(true);
        });
        player.on('error', () => { if (!cancelled) setPlayerError('播放遇到问题，请重新加载视频。'); });
        player.on('video:ratechange', () => { if (!cancelled && player) setSpeed(player.playbackRate); });
        player.on('artplayerPluginDanmuku:hide', () => { if (!cancelled && player?.plugins.artplayerPluginDanmuku) setDanmaku(false); });
        player.on('artplayerPluginDanmuku:show', () => { if (!cancelled && player?.plugins.artplayerPluginDanmuku) setDanmaku(true); });
        setCreated(true);
      } catch (error) { if (!cancelled) setPlayerError(errorMessage(error)); }
    }
    void create();
    return () => {
      cancelled = true;
      removeProgressShortcuts?.();
      qualityRequest.current?.abort(); qualityRequest.current = null; switchPlayback.current = null;
      resumePosition.current = null;
      setQualityBusy(false);
      if (player) { offset.current = player.currentTime || 0; player.pause(); }
      dash?.reset(); player?.destroy(false); playerRef.current = null;
    };
  }, [initial.data, poster]);
  useEffect(() => {
    const player = playerRef.current;
    setHistoryError('');
    if (!created || !player || !accountMid) return;
    let latestRequest = 0, disposed = false;
    async function save(input: WatchProgress) {
      const request = ++latestRequest;
      try {
        await api('/api/history', { method: 'POST', body: input, keepalive: true });
        if (!disposed && request === latestRequest) setHistoryError('');
        window.dispatchEvent(new Event('bilight:history-updated'));
      } catch (error) { if (!disposed && request === latestRequest) setHistoryError(`观看记录未同步：${errorMessage(error)}`); }
    }
    const observer = observeWatchProgress(player.video, (progress, completed) => {
      void save({ bvid, cid, accountMid, progress, completed });
    });
    retryHistory.current = () => observer.flush(true);
    const hide = () => { if (document.visibilityState === 'hidden') observer.flush(); };
    const leave = () => observer.flush();
    document.addEventListener('visibilitychange', hide); window.addEventListener('pagehide', leave);
    return () => {
      observer.dispose(); disposed = true; retryHistory.current = null;
      document.removeEventListener('visibilitychange', hide); window.removeEventListener('pagehide', leave);
    };
  }, [created, bvid, cid, accountMid]);
  useEffect(() => {
    if (!created || !data) return;
    const setting = qualitySetting(data, id => selectQuality.current(id));
    if (qualityBusy) setting.tooltip = '正在切换…';
    playerRef.current?.setting.update(setting);
  }, [data, created, qualityBusy]);
  useEffect(() => { if (ready && playerRef.current) playerRef.current.playbackRate = speed; }, [speed, ready]);
  useEffect(() => {
    const player = playerRef.current;
    if (!created || !player || !data) return;
    const selected = data.subtitles.find(item => item.id === subtitleId);
    if (!selected) { player.subtitle.show = false; return; }
    let cancelled = false;
    // Fetch subtitles as soon as the player exists, without waiting for video canplay.
    player.subtitle.switch(selected.url, { type: 'vtt', escape: true }).then(() => { if (playerRef.current === player) player.subtitle.show = Boolean(wantedSubtitle.current); }).catch(error => { if (!cancelled) setPlayerError(`字幕加载失败：${errorMessage(error)}`); });
    return () => { cancelled = true; };
  }, [subtitleId, created, data]);
  useEffect(() => {
    const player = playerRef.current;
    if (!created || !player) return;
    player.template.$player.classList.toggle('bilight-danmaku-enabled', danmaku);
    const existing = player.plugins.artplayerPluginDanmuku as DanmakuPlugin | undefined;
    if (!danmaku) { existing?.hide(); setDanmakuBusy(false); return; }
    if (existing) { existing.show(); return; }
    const controller = new AbortController(); setDanmakuBusy(true);
    Promise.all([api<Danmaku[]>(`/api/videos/${bvid}/danmaku?cid=${cid}`, { signal: controller.signal }), import('artplayer-plugin-danmuku')]).then(async ([items, { default: plugin }]) => {
      if (controller.signal.aborted || playerRef.current !== player) return;
      const comments: Danmu[] = items.map(item => ({ text: item.text, time: item.time, color: item.color, mode: item.mode === 4 ? 2 : item.mode === 5 ? 1 : 0, style: { fontSize: `${Math.min(36, Math.max(14, item.fontSize))}px` } }));
      await player.plugins.add(plugin({ danmuku: comments, visible: false, emitter: false, heatmap: false, opacity: 0.8, fontSize: 22, antiOverlap: true }));
      const installed = player.plugins.artplayerPluginDanmuku as DanmakuPlugin | undefined;
      if (controller.signal.aborted || playerRef.current !== player) installed?.hide();
      else installed?.show();
    }).catch(error => { if (!isAbort(error)) { setPlayerError(`弹幕加载失败：${errorMessage(error)}`); setDanmaku(false); } }).finally(() => { if (!controller.signal.aborted) setDanmakuBusy(false); });
    return () => controller.abort();
  }, [danmaku, created, bvid, cid]);
  return <section className="player-section" aria-label="视频播放器" aria-keyshortcuts="ArrowLeft ArrowRight">
    <div className="player-shell">{loading ? <Loading text="正在准备视频" /> : error ? <Failure error={error} retry={() => setRefresh(value => value + 1)} /> : <div className="art-player" ref={mount} />}</div>
    {historyError && <p className="history-save-error" role="status">{historyError}<button className="text-button" onClick={() => retryHistory.current?.()}>重试同步</button></p>}
    <div className="playback-toolbar"><div className="playback-options">
      <label><span>清晰度</span><select aria-label="清晰度" value={quality ?? data?.quality ?? ''} disabled={!data || !created || loading} onChange={event => { void selectQuality.current(Number(event.target.value)); }}>{data?.qualities.map(item => <option value={item.id} key={item.id}>{item.label}</option>)}</select></label>
      <label><span>倍速</span><select aria-label="播放速度" value={speed} onChange={event => setSpeed(Number(event.target.value))}>{[0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].map(value => <option key={value} value={value}>{value === 1 ? '正常' : `${value}×`}</option>)}</select></label>
      {Boolean(data?.subtitles.length) && <label><span>字幕</span><select aria-label="字幕" value={subtitleId} onChange={event => setSubtitle(event.target.value)}><option value="">关闭</option>{data?.subtitles.map(item => <option key={item.id} value={item.id}>{item.label}</option>)}</select></label>}
    </div><button className={`danmaku-toggle${danmaku ? ' active' : ''}`} aria-pressed={danmaku} onClick={() => setDanmaku(value => !value)} disabled={!created}>{danmakuBusy ? <SpinnerGap className="spin" size={18} /> : <ChatCircleDots size={18} />}<span>弹幕{danmaku ? '开' : '关'}</span><span className="toggle-track" aria-hidden="true"><span /></span></button></div>
    {playerError && <div className="playback-error" role="alert"><span>{playerError}</span><button className="text-button" onClick={() => setRefresh(value => value + 1)}>重新加载</button></div>}
  </section>;
}
