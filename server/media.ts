import { randomUUID } from 'node:crypto';
import type { Playback } from '../shared/types.js';
import type { BiliGateway, PlaybackSource } from './gateway.js';

type Resource = { url: string; key: string; kind: 'image' | 'video' | 'audio' | 'subtitle'; createdAt: number; renew?: () => Promise<string> };
const MEDIA_DOMAINS = ['bilivideo.com', 'bilivideo.cn', 'bilivideo.net', 'akamaized.net'];
const IMAGE_DOMAINS = ['hdslb.com', 'hdslb.net', 'biliimg.com'];
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';
const escapeXml = (value: unknown) => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' }[c]!));
const rangeValue = (value: string) => /^\d+-\d+$/.test(value) ? value : '';

export function validateMediaUrl(value: string, kind: Resource['kind']): URL {
  const url = new URL(value.startsWith('//') ? `https:${value}` : value);
  const allowed = kind === 'image' || kind === 'subtitle' ? IMAGE_DOMAINS : MEDIA_DOMAINS;
  if (url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443') || !allowed.some(domain => url.hostname === domain || url.hostname.endsWith(`.${domain}`))) {
    throw new Error('不允许的媒体来源');
  }
  return url;
}

export class MediaRegistry {
  private resources = new Map<string, Resource>();
  private keys = new Map<string, string>();
  private manifests = new Map<string, { source: PlaybackSource; expiresAt: number }>();
  private renewals = new Map<string, Promise<string>>();
  constructor(private gateway: BiliGateway, private fetcher: typeof fetch = fetch) {}
  clear(): void { this.resources.clear(); this.keys.clear(); this.manifests.clear(); this.renewals.clear(); }

  register(url: string, kind: Resource['kind'], renew?: () => Promise<string>): string {
    const normalized = validateMediaUrl(url, kind).href;
    const key = `${kind}:${normalized}`;
    const previous = this.keys.get(key);
    const existing = previous ? this.resources.get(previous) : undefined;
    if (existing && Date.now() - existing.createdAt <= 86400000) return `/api/media/${previous}`;
    if (previous) { this.keys.delete(key); this.resources.delete(previous); }
    const id = randomUUID();
    this.resources.set(id, { url: normalized, key, kind, createdAt: Date.now(), renew });
    this.keys.set(key, id);
    while (this.resources.size > 10000) {
      const oldest = this.resources.keys().next().value!;
      const resource = this.resources.get(oldest)!;
      this.keys.delete(resource.key);
      this.resources.delete(oldest);
    }
    return `/api/media/${id}`;
  }

  image(url: string): string {
    if (!url) return '';
    try { return this.register(url, 'image'); } catch { return ''; }
  }

  playback(source: PlaybackSource, bvid: string): Playback {
    const latest = () => this.gateway.playback(bvid, source.cid, source.quality);
    const changedStream = () => Object.assign(new Error('视频格式已发生变化，请重新加载视频。'), { status: 409, code: 'MEDIA_EXPIRED' });
    const renewTrack = async (kind: 'video' | 'audio') => {
      const original = source[kind], renewed = (await latest())[kind];
      const signature = (track: NonNullable<typeof original>) => JSON.stringify([track.id, track.mimeType, track.codecs, track.width, track.height, track.segmentBase]);
      if (!original || !renewed || signature(original) !== signature(renewed) || new URL(original.baseUrl).pathname !== new URL(renewed.baseUrl).pathname) throw changedStream();
      return renewed.baseUrl;
    };
    const mapped: Playback = { cid: source.cid, quality: source.quality, qualities: source.qualities, subtitles: source.subtitles.map(sub => ({ ...sub, url: `${this.register(sub.url, 'subtitle')}/subtitle.vtt` })) };
    if (source.video) {
      const video = { ...source.video, baseUrl: this.register(source.video.baseUrl, 'video', () => renewTrack('video')) };
      const audio = source.audio ? { ...source.audio, baseUrl: this.register(source.audio.baseUrl, 'audio', () => renewTrack('audio')) } : undefined;
      const id = randomUUID();
      this.manifests.set(id, { source: { ...source, video, audio }, expiresAt: Date.now() + 86400000 });
      for (const [key, manifest] of this.manifests) if (manifest.expiresAt < Date.now()) this.manifests.delete(key);
      while (this.manifests.size > 200) this.manifests.delete(this.manifests.keys().next().value!);
      mapped.manifestUrl = `/api/media/${id}/manifest.mpd`;
    } else if (source.segments?.length === 1) {
      mapped.mp4Url = this.register(source.segments[0].url, 'video', async () => {
        const renewed = (await latest()).segments;
        if (renewed?.length !== 1 || renewed[0].length !== source.segments![0].length || new URL(renewed[0].url).pathname !== new URL(source.segments![0].url).pathname) throw changedStream();
        return renewed[0].url;
      });
    } else { throw Object.assign(new Error('该视频暂时没有可在 Safari 中播放的音视频格式。'), { status: 422, code: 'UNSUPPORTED_STREAM' }); }
    return mapped;
  }

  manifest(id: string): string | undefined {
    const item = this.manifests.get(id);
    if (!item || item.expiresAt < Date.now()) return undefined;
    const source = item.source;
    const tracks = [source.video!, ...(source.audio ? [source.audio] : [])];
    const adaptations = tracks.map((track, index) => {
      const isVideo = index === 0;
      const attrs = [`id="${index}"`, `mimeType="${escapeXml(track.mimeType)}"`, `codecs="${escapeXml(track.codecs)}"`, `bandwidth="${Math.max(1, Number(track.bandwidth) || 1)}"`];
      if (isVideo) attrs.push(`width="${Number(track.width) || 1920}"`, `height="${Number(track.height) || 1080}"`);
      return `<AdaptationSet contentType="${isVideo ? 'video' : 'audio'}" segmentAlignment="true"><Representation ${attrs.join(' ')}><BaseURL>${escapeXml(track.baseUrl)}</BaseURL><SegmentBase indexRange="${rangeValue(track.segmentBase.indexRange)}"><Initialization range="${rangeValue(track.segmentBase.initialization)}"/></SegmentBase></Representation></AdaptationSet>`;
    }).join('');
    return `<?xml version="1.0" encoding="UTF-8"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" type="static" mediaPresentationDuration="PT${Math.max(1, source.duration)}S" minBufferTime="PT1.5S"><Period duration="PT${Math.max(1, source.duration)}S">${adaptations}</Period></MPD>`;
  }

  async fetch(id: string, range?: string, head = false, signal?: AbortSignal): Promise<{ response: Response; kind: Resource['kind'] } | undefined> {
    const resource = this.resources.get(id);
    if (!resource || Date.now() - resource.createdAt > 86400000) return undefined;
    if (range && !/^bytes=\d*-\d*$/.test(range)) throw Object.assign(new Error('不支持的播放范围。'), { status: 416, code: 'INVALID_RANGE' });
    const download = async () => {
      let url = validateMediaUrl(resource.url, resource.kind).href;
      for (let redirects = 0; redirects < 4; redirects++) {
        const timeout = AbortSignal.timeout(60000);
        const requestSignal = signal ? AbortSignal.any([signal, timeout]) : timeout;
        const response = await this.fetcher(url, { method: head ? 'HEAD' : 'GET', headers: { 'User-Agent': UA, Referer: 'https://www.bilibili.com/', 'Accept-Encoding': 'identity', ...(range ? { Range: range } : {}) }, redirect: 'manual', signal: requestSignal });
        if ([301, 302, 303, 307, 308].includes(response.status)) {
          const location = response.headers.get('location');
          await response.body?.cancel();
          if (!location) throw new Error('媒体跳转缺少目标');
          url = validateMediaUrl(new URL(location, url).href, resource.kind).href;
          continue;
        }
        return response;
      }
      throw new Error('媒体跳转次数过多');
    };
    let response = await download();
    if ([401, 403, 410].includes(response.status) && resource.renew) {
      await response.body?.cancel();
      let pending = this.renewals.get(id);
      if (!pending) {
        pending = resource.renew().finally(() => this.renewals.delete(id));
        this.renewals.set(id, pending);
      }
      resource.url = validateMediaUrl(await pending, resource.kind).href;
      response = await download();
    }
    return { response, kind: resource.kind };
  }

  async subtitle(id: string): Promise<string | undefined> {
    if (this.resources.get(id)?.kind !== 'subtitle') return undefined;
    const result = await this.fetch(id);
    if (!result?.response.ok) throw Object.assign(new Error('字幕暂时无法加载。'), { status: 502, code: 'SUBTITLE_UNAVAILABLE' });
    const text = await result.response.text();
    if (text.length > 2000000) throw new Error('字幕数据过大');
    const body = JSON.parse(text).body;
    if (!Array.isArray(body)) throw new Error('字幕格式不受支持');
    const timestamp = (value: number) => {
      const ms = Math.max(0, Math.round(value * 1000));
      return `${String(Math.floor(ms / 3600000)).padStart(2, '0')}:${String(Math.floor(ms / 60000) % 60).padStart(2, '0')}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}.${String(ms % 1000).padStart(3, '0')}`;
    };
    return `WEBVTT\n\n${body.filter(item => Number.isFinite(item.from) && Number.isFinite(item.to) && item.to > item.from).map((item, i) => `${i + 1}\n${timestamp(item.from)} --> ${timestamp(item.to)}\n${String(item.content ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\r?\n\r?\n/g, '\n')}\n`).join('\n')}`;
  }
}
