import { randomUUID } from 'node:crypto';
import type { Playback } from '../shared/types.js';
import type { BiliGateway, PlaybackSource } from './gateway.js';

type RenewedResource = string | { url: string; backups: string[] };
type Resource = { url: string; backups: string[]; preferred?: string; key: string; kind: 'image' | 'video' | 'audio' | 'subtitle'; createdAt: number; renew?: () => Promise<RenewedResource> };
const MEDIA_DOMAINS = ['bilivideo.com', 'bilivideo.cn', 'bilivideo.net', 'akamaized.net'];
const IMAGE_DOMAINS = ['hdslb.com', 'hdslb.net', 'biliimg.com'];
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';
const escapeXml = (value: unknown) => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' }[c]!));
const rangeValue = (value: string) => /^\d+-\d+$/.test(value) ? value : '';
const MEDIA_TYPES = new Set(['video/mp4', 'audio/mp4', 'audio/x-m4a', 'video/x-m4v', 'application/mp4', 'application/octet-stream']);
const RANGE_CHUNK = 1024 * 1024;

function usableCandidate(response: Response, range?: string): boolean {
  if (response.status === 416) return true;
  if (!MEDIA_TYPES.has((response.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase())) return false;
  if (!range) return true;
  const actual = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('content-range') ?? '');
  if (response.status !== 206 || !actual) return false;
  const [start, end, total] = actual.slice(1).map(Number), [from, to] = range.slice(6).split('-');
  if (![start, end, total].every(Number.isSafeInteger) || start > end || end >= total) return false;
  const wantedStart = from ? Number(from) : Math.max(0, total - Number(to));
  const wantedEnd = from && to ? Math.min(Number(to), total - 1) : total - 1;
  const length = response.headers.get('content-length');
  return start === wantedStart && end === wantedEnd && (!length || Number(length) === end - start + 1);
}

function parallelRangeResponse(first: Response, start: number, end: number, total: number, readRange: (range: string, signal: AbortSignal) => Promise<Response>): Response {
  const etag = first.headers.get('etag')!, type = first.headers.get('content-type');
  const cancellation = new AbortController(), queue = new Map<number, Promise<Uint8Array>>();
  const count = Math.ceil((end - start + 1) / RANGE_CHUNK);
  let next = 0, scheduled = 0;
  const invalid = () => Object.assign(new Error('视频分段的文件标识、长度或字节范围发生变化，请重新加载。'), { status: 409, code: 'MEDIA_CHANGED' });
  async function chunk(index: number): Promise<Uint8Array> {
    const from = start + index * RANGE_CHUNK, to = Math.min(end, from + RANGE_CHUNK - 1), range = `bytes=${from}-${to}`;
    const response = index === 0 ? first : await readRange(range, cancellation.signal);
    if (cancellation.signal.aborted) { await response.body?.cancel(); throw cancellation.signal.reason; }
    if (!usableCandidate(response, range) || response.headers.get('etag') !== etag || response.headers.get('content-type') !== type || response.headers.get('content-range') !== `bytes ${from}-${to}/${total}`) {
      await response.body?.cancel(); throw invalid();
    }
    const reader = response.body?.getReader();
    if (!reader) throw invalid();
    const bytes = new Uint8Array(to - from + 1);
    const abort = () => { void reader.cancel(cancellation.signal.reason).catch(() => {}); };
    cancellation.signal.addEventListener('abort', abort, { once: true });
    let offset = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        if (offset + value.byteLength > bytes.byteLength) throw invalid();
        bytes.set(value, offset); offset += value.byteLength;
      }
      if (cancellation.signal.aborted) throw cancellation.signal.reason;
      if (offset !== bytes.byteLength) throw invalid();
      return bytes;
    } catch (error) { await reader.cancel().catch(() => {}); throw error; }
    finally { cancellation.signal.removeEventListener('abort', abort); reader.releaseLock(); }
  }
  function fill() {
    // At most three 1 MiB ranges in flight, plus one chunk in the consumer's stream queue.
    while (scheduled < count && queue.size < 3 && !cancellation.signal.aborted) {
      const index = scheduled++;
      const pending = chunk(index).catch(error => { cancellation.abort(error); throw error; });
      pending.catch(() => {}); queue.set(index, pending);
    }
  }
  const body = new ReadableStream<Uint8Array>({
    start() { fill(); },
    async pull(controller) {
      try {
        if (cancellation.signal.aborted) throw cancellation.signal.reason;
        const bytes = await queue.get(next)!;
        queue.delete(next++); controller.enqueue(bytes);
        if (next === count) controller.close(); else fill();
      } catch (error) { cancellation.abort(error); controller.error(error); }
    },
    cancel(reason) { cancellation.abort(reason); },
  });
  const headers = new Headers(first.headers);
  headers.set('content-range', `bytes ${start}-${end}/${total}`);
  headers.set('content-length', String(end - start + 1));
  return new Response(body, { status: 206, headers });
}

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
  private renewals = new Map<string, Promise<RenewedResource>>();
  constructor(private gateway: BiliGateway, private fetcher: typeof fetch = fetch) {}
  clear(): void { this.resources.clear(); this.keys.clear(); this.manifests.clear(); this.renewals.clear(); }

  register(url: string, kind: Resource['kind'], renew?: () => Promise<RenewedResource>, backups: string[] = []): string {
    const normalized = validateMediaUrl(url, kind).href;
    const alternatives = [...new Set(backups.flatMap(value => { try { return [validateMediaUrl(value, kind).href]; } catch { return []; } }))].filter(value => value !== normalized).slice(0, 2);
    const key = `${kind}:${normalized}`;
    const previous = this.keys.get(key);
    const existing = previous ? this.resources.get(previous) : undefined;
    if (existing && Date.now() - existing.createdAt <= 86400000) return `/api/media/${previous}`;
    if (previous) { this.keys.delete(key); this.resources.delete(previous); }
    const id = randomUUID();
    this.resources.set(id, { url: normalized, backups: alternatives, key, kind, createdAt: Date.now(), renew });
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
      return { url: renewed.baseUrl, backups: renewed.backupUrl ?? [] };
    };
    const mapped: Playback = { cid: source.cid, quality: source.quality, qualities: source.qualities, subtitles: source.subtitles.map(sub => ({ ...sub, url: `${this.register(sub.url, 'subtitle')}/subtitle.vtt` })) };
    if (source.video) {
      const video = { ...source.video, baseUrl: this.register(source.video.baseUrl, 'video', () => renewTrack('video'), source.video.backupUrl) };
      const audio = source.audio ? { ...source.audio, baseUrl: this.register(source.audio.baseUrl, 'audio', () => renewTrack('audio'), source.audio.backupUrl) } : undefined;
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
    const responseUrls = new WeakMap<Response, string>();
    const downloadFrom = async (value: string, cancellation?: AbortSignal, byteRange = range) => {
      let url = validateMediaUrl(value, resource.kind).href;
      for (let redirects = 0; redirects < 4; redirects++) {
        const timeout = AbortSignal.timeout(60000);
        const signals = [timeout, ...(signal ? [signal] : []), ...(cancellation ? [cancellation] : [])];
        const requestSignal = signals.length === 1 ? timeout : AbortSignal.any(signals);
        const response = await this.fetcher(url, { method: head ? 'HEAD' : 'GET', headers: { 'User-Agent': UA, Referer: 'https://www.bilibili.com/', 'Accept-Encoding': 'identity', ...(byteRange ? { Range: byteRange } : {}) }, redirect: 'manual', signal: requestSignal });
        if ([301, 302, 303, 307, 308].includes(response.status)) {
          const location = response.headers.get('location');
          await response.body?.cancel();
          if (!location) throw new Error('媒体跳转缺少目标');
          url = validateMediaUrl(new URL(location, url).href, resource.kind).href;
          continue;
        }
        responseUrls.set(response, url); return response;
      }
      throw new Error('媒体跳转次数过多');
    };
    const download = async (byteRange = range) => {
      if (!resource.backups.length) return downloadFrom(resource.url, undefined, byteRange);
      if (resource.preferred) {
        try {
          const response = await downloadFrom(resource.preferred, undefined, byteRange);
          if (response.ok && usableCandidate(response, byteRange)) return response;
          await response.body?.cancel();
        } catch (error) { if (signal?.aborted) throw error; }
        resource.preferred = undefined;
      }
      // Race only the first response headers, then stream the winning body with backpressure.
      // All candidates are platform-supplied URLs for this exact rendition; no bytes are spliced.
      const candidates = [resource.url, ...resource.backups], controllers = candidates.map(() => new AbortController());
      const attempts = candidates.map(async (url, index) => {
        const response = await downloadFrom(url, controllers[index].signal, byteRange);
        if (!response.ok) { await response.body?.cancel(); throw response; }
        if (!usableCandidate(response, byteRange)) {
          await response.body?.cancel();
          throw Object.assign(new Error('媒体返回了不匹配的格式或字节范围。'), { status: 502, code: 'INVALID_MEDIA' });
        }
        return { response, index };
      });
      try {
        const winner = await Promise.any(attempts);
        resource.preferred = candidates[winner.index];
        controllers.forEach((controller, index) => { if (index !== winner.index) controller.abort(); });
        return winner.response;
      } catch (error) {
        controllers.forEach(controller => controller.abort());
        if (signal?.aborted) throw signal.reason;
        const failures: unknown[] = error instanceof AggregateError ? error.errors : [error];
        const expired = failures.find(value => value instanceof Response && [401, 403, 410].includes(value.status));
        if (expired instanceof Response) return expired;
        const failure = failures[0];
        if (failure instanceof Response) return failure;
        throw failure;
      }
    };
    const closedRange = /^bytes=(\d+)-(\d+)$/.exec(range ?? '')?.slice(1).map(Number);
    // A shared Akamai edge can alternate storage-specific ETags for one file. Keep its fast
    // small reads, but combine ranges only from a direct platform mirror with stable validators.
    const directMirror = () => [resource.url, ...resource.backups].find(value => !/(^|\.)akamaized\.net$/.test(new URL(value).hostname));
    let mirror = directMirror();
    let split = !head && !!mirror && (resource.kind === 'video' || resource.kind === 'audio') && closedRange?.every(Number.isSafeInteger) && closedRange[1] - closedRange[0] + 1 > 2 * RANGE_CHUNK;
    let firstRange = split ? `bytes=${closedRange![0]}-${closedRange![0] + RANGE_CHUNK - 1}` : range;
    const downloadFirst = async () => {
      if (split) {
        try {
          const response = await downloadFrom(mirror!, undefined, firstRange);
          if (response.ok && usableCandidate(response, firstRange)) return response;
          await response.body?.cancel();
        } catch (error) { if (signal?.aborted) throw error; }
        split = false; firstRange = range;
      }
      return download(firstRange);
    };
    let response = await downloadFirst();
    if ([401, 403, 410].includes(response.status) && resource.renew) {
      await response.body?.cancel();
      let pending = this.renewals.get(id);
      if (!pending) {
        pending = resource.renew().finally(() => this.renewals.delete(id));
        this.renewals.set(id, pending);
      }
      const renewed = await pending;
      resource.url = validateMediaUrl(typeof renewed === 'string' ? renewed : renewed.url, resource.kind).href;
      resource.backups = typeof renewed === 'string' ? [] : renewed.backups.flatMap(value => { try { return [validateMediaUrl(value, resource.kind).href]; } catch { return []; } }).filter(value => value !== resource.url).slice(0, 2);
      resource.preferred = undefined;
      mirror = directMirror();
      if (split && !mirror) { split = false; firstRange = range; }
      response = await downloadFirst();
    }
    if (split && response.ok) {
      const etag = response.headers.get('etag');
      if (!usableCandidate(response, firstRange)) { await response.body?.cancel(); throw Object.assign(new Error('媒体返回了不匹配的字节范围。'), { status: 502, code: 'INVALID_MEDIA' }); }
      if (!etag || !/^"[^"\r\n]*"$/.test(etag)) {
        // Combining separate responses requires the same strong validator (RFC 9110 15.3.7.3).
        await response.body?.cancel(); response = await download(range);
      } else {
        const total = Number(response.headers.get('content-range')!.split('/')[1]);
        const url = responseUrls.get(response)!, end = Math.min(closedRange![1], total - 1);
        response = parallelRangeResponse(response, closedRange![0], end, total, (part, signal) => downloadFrom(url, signal, part));
      }
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
