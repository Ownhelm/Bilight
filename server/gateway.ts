import { XMLParser, XMLValidator } from 'fast-xml-parser';
import type { CoinInfo, CollectionKind, CollectionPage, Comment, CreatorCollection, CreatorSummary, Danmaku, EngagementAction, FavoriteFolder, HistoryItem, Page, Quality, SearchPage, Subtitle, TripleResult, User, VideoDetail, VideoEngagement, VideoPart, VideoSummary } from '../shared/types.js';
import { BiliError, type BiliHttp } from './transport.js';

type RecordValue = Record<string, any>;
const API = 'https://api.bilibili.com';
const BVID = /^BV[0-9A-Za-z]{10}$/;
const LINK_HOSTS = new Set(['bilibili.com', 'www.bilibili.com', 'm.bilibili.com', 'search.bilibili.com', 'space.bilibili.com', 'b23.tv', 'www.b23.tv']);

export interface DashTrack {
  id: number; baseUrl: string; backupUrl?: string[]; mimeType: string; codecs: string; bandwidth: number;
  width?: number; height?: number; frameRate?: string; segmentBase: { initialization: string; indexRange: string };
}
export interface PlaybackSource {
  cid: number; quality: number; qualities: Quality[]; duration: number; video?: DashTrack; audio?: DashTrack;
  segments?: { url: string; length: number }[]; subtitles: Subtitle[];
}

function object(value: unknown): RecordValue { return value && typeof value === 'object' && !Array.isArray(value) ? value as RecordValue : {}; }
function array(value: unknown): RecordValue[] { return Array.isArray(value) ? value.map(object) : []; }
function number(value: unknown, fallback = 0): number {
  const parsed = Number(value); return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}
function integer(value: unknown, label: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new BiliError('INVALID_INPUT', `${label}无效`, 400);
  return parsed;
}
function clean(value: unknown, limit = 300): string {
  if (typeof value !== 'string' && typeof value !== 'number') return '';
  return String(value).replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, '').replace(/<style\b[^>]*>[\s\S]*?<\/style\s*>/gi, '')
    .replace(/<[^>]*>/g, '').replace(/&(?:#(\d+)|#x([\da-f]+)|amp|lt|gt|quot|apos|nbsp);/gi, (match, dec, hex) => {
      if (dec || hex) { const point = parseInt(dec || hex, dec ? 10 : 16); return point > 0 && point <= 0x10ffff ? String.fromCodePoint(point) : ''; }
      return ({ '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&apos;': "'", '&nbsp;': ' ' } as Record<string, string>)[match.toLowerCase()] ?? '';
    }).replace(/<[^>]*>/g, '').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '').slice(0, limit).trim();
}
function https(value: unknown): string {
  if (typeof value !== 'string' || value.length > 8192) return '';
  try {
    const url = new URL(value.startsWith('//') ? `https:${value}` : value);
    if (url.protocol === 'http:' && /\.(?:hdslb\.com|bilivideo\.com|bilivideo\.cn)$/.test(url.hostname)) url.protocol = 'https:';
    return url.protocol === 'https:' && !url.username && !url.password && (!url.port || url.port === '443') ? url.href : '';
  } catch { return ''; }
}
function duration(value: unknown): number {
  if (typeof value === 'string' && value.includes(':')) return value.split(':').reduce((sum, part) => sum * 60 + number(part), 0);
  return number(value);
}
function count(value: unknown): number {
  if (typeof value === 'string') { const unit = value.endsWith('万') ? 1e4 : value.endsWith('亿') ? 1e8 : 1; return number(parseFloat(value)) * unit; }
  return number(value);
}
function user(value: unknown): User {
  const data = object(value); return { mid: number(data.mid ?? data.uid), name: clean(data.name ?? data.uname), avatar: https(data.face ?? data.avatar ?? data.upic) };
}
function videoSummary(value: unknown, fallbackOwner?: User): VideoSummary | undefined {
  const data = object(value), bvid = typeof data.bvid === 'string' ? data.bvid.trim() : '';
  if (!BVID.test(bvid)) return undefined;
  const owner = data.owner ? user(data.owner) : fallbackOwner ?? user({ mid: data.mid, name: data.author, face: data.upic });
  return { bvid, aid: number(data.aid ?? data.id), title: clean(data.title, 1000), cover: https(data.pic ?? data.cover), duration: duration(data.duration ?? data.length ?? data.duration_text), publishedAt: number(data.pubdate ?? data.created ?? data.publishedAt), owner, views: count(data.play ?? object(data.stat).view ?? object(data.stat).play) };
}
function uniqueVideos(items: VideoSummary[]): VideoSummary[] {
  const seen = new Set<string>(); return items.filter(item => !seen.has(item.bvid) && Boolean(seen.add(item.bvid)));
}
function validBvid(value: string): string {
  if (!BVID.test(value)) throw new BiliError('INVALID_INPUT', '视频编号无效', 400); return value;
}

function collectionSummary(raw: RecordValue, kind: CollectionKind, mid: number): CreatorCollection {
  const meta = object(raw.meta), id = number(kind === 'season' ? meta.season_id : meta.series_id);
  if (!id || number(meta.mid) !== mid) throw new BiliError('COLLECTION_UNAVAILABLE', '合集或列表信息不完整，暂时无法读取');
  return { id, mid, kind, title: clean(meta.name || meta.title, 1000), description: clean(meta.description, 5000), cover: https(meta.cover) || https(array(raw.archives)[0]?.pic), count: number(meta.total ?? meta.count), updatedAt: number(meta.ptime ?? meta.mtime ?? meta.ctime) };
}

function historyPosition(value?: string): { max: number; view_at: number; business: string } | undefined {
  if (!value) return;
  try {
    if (value.length > 600 || !/^[\w-]+$/.test(value)) throw new Error();
    const data = JSON.parse(Buffer.from(value, 'base64url').toString('utf8'));
    if (!Number.isSafeInteger(data.max) || data.max <= 0 || !Number.isSafeInteger(data.view_at) || data.view_at <= 0 || typeof data.business !== 'string' || !/^[a-z_]{1,32}$/.test(data.business)) throw new Error();
    return { max: data.max, view_at: data.view_at, business: data.business };
  } catch { throw new BiliError('INVALID_INPUT', '历史记录分页标识无效，请刷新列表', 400); }
}

export class BiliGateway {
  private followCache?: { expires: number; mid: number; ids: Set<number> };
  private readonly followRequests = new Map<number, Promise<Set<number>>>();
  private followJar?: BiliHttp['jar'];
  private readonly videoCache = new Map<string, { expires: number; request: Promise<VideoDetail> }>();
  private videoJar?: BiliHttp['jar'];
  private tripleJar?: BiliHttp['jar'];
  private readonly triples = new Map<string, Promise<TripleResult>>();
  private readonly interactions = new Map<string, { key: string; request: Promise<VideoEngagement> }>();
  private readonly folderCreations = new WeakMap<BiliHttp['jar'], Map<string, Promise<FavoriteFolder>>>();
  constructor(private readonly transport: BiliHttp) {}

  async reportHistory(video: VideoDetail, part: VideoPart, progress: number): Promise<void> {
    if (!Number.isSafeInteger(video.aid) || video.aid <= 0 || !video.parts.some(item => item.cid === part.cid) || !Number.isFinite(progress) || progress < 0) throw new BiliError('INVALID_PROGRESS', '观看进度或分 P 不正确', 400);
    const { jar, csrf } = await this.interactionCredentials();
    await this.prepareInteraction(jar);
    // This endpoint records history only; do not fabricate playback heartbeats or elapsed watch time.
    await this.transport.request(`${API}/x/v2/history/report`, { method: 'POST', form: { aid: video.aid, cid: part.cid, progress: Math.floor(part.duration > 0 ? Math.min(progress, part.duration) : progress), csrf }, headers: { origin: 'https://www.bilibili.com', referer: `https://www.bilibili.com/video/${video.bvid}` } });
    this.checkAccount(jar);
  }

  async history(cursor?: string, limit = 20): Promise<Page<HistoryItem>> {
    const position = historyPosition(cursor), ps = Math.min(20, integer(limit, '每页数量')), jar = this.transport.jar;
    const data = await this.transport.request<RecordValue>(`${API}/x/web-interface/history/cursor`, { query: { ...position, ps, type: 'archive' } });
    if (this.transport.jar !== jar) throw new BiliError('LOGIN_REQUIRED', '账号状态已变化，请重新打开历史记录', 401);
    if (!Array.isArray(data.list) || !data.cursor || typeof data.cursor !== 'object') throw new BiliError('HISTORY_UNAVAILABLE', '播放历史暂时无法完整读取，请重试');
    const seen = new Set<string>(), items: HistoryItem[] = [];
    for (const entry of array(data.list)) {
      const history = object(entry.history);
      if (history.business !== 'archive' || !BVID.test(String(history.bvid)) || seen.has(history.bvid)) continue;
      const mapped = videoSummary({ bvid: history.bvid, aid: history.oid, title: entry.title, pic: entry.cover, duration: entry.duration }, user({ mid: entry.author_mid, name: entry.author_name, face: entry.author_face }));
      if (!mapped) continue;
      seen.add(mapped.bvid);
      const progress = Number(entry.progress);
      items.push({ ...mapped, cid: number(history.cid), page: Math.max(1, number(history.page, 1)), part: clean(history.part, 1000), viewedAt: number(entry.view_at), progress: progress === -1 ? -1 : Number.isFinite(progress) && progress >= 0 ? Math.min(progress, mapped.duration || progress) : 0 });
    }
    const raw = object(data.cursor), next = { max: number(raw.max), view_at: number(raw.view_at), business: clean(raw.business, 32) };
    const nextCursor = data.list.length && Number.isSafeInteger(next.max) && next.max > 0 && Number.isSafeInteger(next.view_at) && next.view_at > 0 && /^[a-z_]{1,32}$/.test(next.business) ? Buffer.from(JSON.stringify(next)).toString('base64url') : '';
    const hasMore = Boolean(nextCursor) && nextCursor !== cursor;
    return { items: items.sort((a, b) => b.viewedAt - a.viewedAt), hasMore, ...(hasMore ? { nextCursor } : {}) };
  }

  async creatorCollections(mid: number, page = 1): Promise<Page<CreatorCollection>> {
    const id = integer(mid, 'UP 主编号'), pn = integer(page, '页码');
    const data = await this.transport.request<RecordValue>(`${API}/x/polymer/web-space/seasons_series_list`, { query: { mid: id, page_num: pn, page_size: 12 }, headers: { referer: `https://space.bilibili.com/${id}/lists` } });
    const lists = object(data.items_lists), paging = object(lists.page);
    if (!Array.isArray(lists.seasons_list) || !Array.isArray(lists.series_list) || !Number.isFinite(Number(paging.total))) throw new BiliError('COLLECTIONS_UNAVAILABLE', '合集和视频列表暂时无法完整读取，请重试');
    const items = [...array(lists.seasons_list).map(raw => collectionSummary(raw, 'season', id)), ...array(lists.series_list).map(raw => collectionSummary(raw, 'series', id))];
    const hasMore = pn * number(paging.page_size, 12) < number(paging.total);
    return { items, hasMore, ...(hasMore ? { nextPage: pn + 1 } : {}) };
  }

  async collection(mid: number, kind: CollectionKind, collectionId: number, page = 1): Promise<CollectionPage> {
    const id = integer(mid, 'UP 主编号'), target = integer(collectionId, '合集或列表编号'), pn = integer(page, '页码');
    if (kind !== 'season' && kind !== 'series') throw new BiliError('INVALID_INPUT', '合集或列表类型无效', 400);
    const headers = { referer: `https://space.bilibili.com/${id}/lists` };
    let data: RecordValue, collection: CreatorCollection;
    if (kind === 'season') {
      data = await this.transport.request<RecordValue>(`${API}/x/polymer/web-space/seasons_archives_list`, { headers, query: { mid: id, season_id: target, sort_reverse: false, page_num: pn, page_size: 30 } });
      collection = collectionSummary(data, kind, id);
    } else {
      const [meta, archives] = await Promise.all([
        this.transport.request<RecordValue>(`${API}/x/series/series`, { headers, query: { series_id: target } }),
        this.transport.request<RecordValue>(`${API}/x/series/archives`, { headers, query: { mid: id, series_id: target, only_normal: true, sort: 'desc', pn, ps: 30 } }),
      ]);
      data = archives; collection = collectionSummary(meta, kind, id);
    }
    if (collection.id !== target) throw new BiliError('COLLECTION_UNAVAILABLE', '合集或列表与当前 UP 主不匹配', 404);
    if (!Array.isArray(data.archives)) throw new BiliError('COLLECTION_UNAVAILABLE', '合集或列表视频暂时无法完整读取，请重试');
    const items = uniqueVideos(array(data.archives).map(raw => videoSummary(raw, { mid: id, name: '', avatar: '' })).filter((item): item is VideoSummary => Boolean(item)));
    const paging = object(data.page), total = number(paging.total, collection.count), size = number(paging.page_size ?? paging.size, 30), hasMore = pn * size < total;
    return { collection: { ...collection, count: total }, items, hasMore, ...(hasMore ? { nextPage: pn + 1 } : {}) };
  }

  async engagement(bvid: string): Promise<VideoEngagement> {
    validBvid(bvid);
    const data = await this.transport.request<RecordValue>(`${API}/x/web-interface/archive/relation`, { query: { bvid } });
    if (typeof data?.like !== 'boolean' || typeof data?.favorite !== 'boolean' || !Number.isSafeInteger(data?.coin) || data.coin < 0) throw new BiliError('INVALID_RESPONSE', '暂时无法确认点赞、投币和收藏状态');
    return { liked: data.like, coins: data.coin, favorited: data.favorite };
  }

  async triple(bvid: string): Promise<TripleResult> {
    validBvid(bvid);
    const jar = this.transport.jar;
    if (this.tripleJar !== jar) { this.triples.clear(); this.interactions.clear(); this.tripleJar = jar; }
    if (this.interactions.has(bvid)) throw new BiliError('INTERACTION_BUSY', '这个视频的互动正在处理中，请稍后重试', 409);
    const pending = this.triples.get(bvid);
    if (pending) return pending;
    const task = this.performTriple(bvid, jar); this.triples.set(bvid, task);
    try { return await task; }
    finally { if (this.triples.get(bvid) === task) this.triples.delete(bvid); }
  }

  private async interactionCredentials() {
    const jar = this.transport.jar, cookies = await jar.getCookies(API);
    const csrf = cookies.find(cookie => cookie.key === 'bili_jct')?.value;
    if (!csrf || !cookies.some(cookie => cookie.key === 'SESSDATA')) throw new BiliError('LOGIN_REQUIRED', '登录 B 站后即可支持 UP 主', 401);
    return { jar, csrf, mid: number(cookies.find(cookie => cookie.key === 'DedeUserID')?.value) };
  }

  private checkAccount(jar: BiliHttp['jar']) {
    if (this.transport.jar !== jar) throw new BiliError('LOGIN_REQUIRED', '账号状态已变化，请重新确认互动状态', 401);
  }

  private async prepareInteraction(jar: BiliHttp['jar']) {
    this.checkAccount(jar); await this.transport.ensureDeviceCookies(); this.checkAccount(jar);
  }

  async coinInfo(bvid: string): Promise<CoinInfo> {
    validBvid(bvid); const { jar } = await this.interactionCredentials();
    const [video, state] = await Promise.all([this.video(bvid), this.engagement(bvid)]);
    this.checkAccount(jar);
    return { state, coinLimit: video.interaction?.coinLimit ?? 2 };
  }

  async coinExperience(): Promise<number> {
    const { jar } = await this.interactionCredentials(), experience = await this.transport.request<number>(`${API}/x/web-interface/coin/today/exp`);
    this.checkAccount(jar);
    if (!Number.isFinite(experience) || experience < 0 || experience > 50) throw new BiliError('COIN_INFO_UNAVAILABLE', '暂时无法读取今日投币经验，请重试');
    return experience;
  }

  async favoriteFolders(bvid: string): Promise<FavoriteFolder[]> {
    validBvid(bvid);
    const { jar, mid } = await this.interactionCredentials();
    if (!mid) throw new BiliError('LOGIN_REQUIRED', '账号信息不完整，请重新登录', 401);
    const video = await this.video(bvid); this.checkAccount(jar);
    const data = await this.transport.request<RecordValue>(`${API}/x/v3/fav/folder/created/list-all`, { query: { up_mid: mid, rid: video.aid, type: 2 } });
    this.checkAccount(jar);
    const entries = data?.list === null && data.count === 0 ? [] : data?.list;
    if (!Array.isArray(entries) || data.count !== entries.length) throw new BiliError('FOLDERS_UNAVAILABLE', '收藏夹暂时无法完整读取，请重试');
    return array(entries).map(folder => {
      if (!Number.isSafeInteger(folder.id) || folder.id <= 0 || number(folder.mid) !== mid || ![0, 1].includes(folder.fav_state)) throw new BiliError('FOLDERS_UNAVAILABLE', '收藏夹信息不完整，请重试');
      const attr = number(folder.attr), isDefault = (attr & 2) === 0;
      return { id: folder.id, title: clean(folder.title), count: number(folder.media_count), selected: folder.fav_state === 1, isPrivate: Boolean(attr & 1), isDefault, capacity: number(folder.max_count) || (isDefault ? 50_000 : 1000) };
    }).sort((a, b) => Number(b.selected) - Number(a.selected));
  }

  async createFavoriteFolder(bvid: string, name: string): Promise<FavoriteFolder> {
    validBvid(bvid); const title = typeof name === 'string' ? name.trim() : '';
    if (!title || title.length > 20 || /[\u0000-\u001f\u007f]/.test(title)) throw new BiliError('INVALID_FOLDER_NAME', '收藏夹名称需为1至20个字', 400);
    const jar = this.transport.jar;
    let requests = this.folderCreations.get(jar);
    if (!requests) { requests = new Map(); this.folderCreations.set(jar, requests); }
    const pending = requests.get(title); if (pending) return pending;
    const request = (async () => {
      const { csrf } = await this.interactionCredentials(), folders = await this.favoriteFolders(bvid);
      if (folders.length >= 100) throw new BiliError('FOLDER_LIMIT', '收藏夹个数已达到上限', 409);
      await this.prepareInteraction(jar);
      const created = await this.transport.request<RecordValue>(`${API}/x/v3/fav/folder/add`, { method: 'POST', headers: { origin: 'https://www.bilibili.com', referer: `https://www.bilibili.com/video/${bvid}` }, form: { title, privacy: 0, csrf } });
      this.checkAccount(jar);
      const folder = (await this.favoriteFolders(bvid)).find(item => item.id === created?.id);
      if (!folder) throw new BiliError('FOLDER_UNCONFIRMED', '新建请求已提交，请刷新收藏夹列表确认，避免重复新建');
      return folder;
    })();
    requests.set(title, request);
    try { return await request; } finally { if (requests.get(title) === request) requests.delete(title); }
  }

  async interact(bvid: string, action: EngagementAction): Promise<VideoEngagement> {
    validBvid(bvid);
    if (!action || (action.type === 'like' ? typeof action.liked !== 'boolean' : action.type === 'coin' ? ![1, 2].includes(action.coins) || action.selectLike !== undefined && typeof action.selectLike !== 'boolean' : action.type === 'favorite' ? !Array.isArray(action.folderIds) || action.folderIds.length > 100 || action.folderIds.some(id => !Number.isSafeInteger(id) || id <= 0) : true)) throw new BiliError('INVALID_INPUT', '互动参数无效', 400);
    const jar = this.transport.jar;
    if (this.tripleJar !== jar) { this.triples.clear(); this.interactions.clear(); this.tripleJar = jar; }
    if (this.triples.has(bvid)) throw new BiliError('INTERACTION_BUSY', '一键三连正在处理中，请稍后重试', 409);
    const key = JSON.stringify(action), pending = this.interactions.get(bvid);
    if (pending) { if (pending.key === key) return pending.request; throw new BiliError('INTERACTION_BUSY', '这个视频的互动正在处理中，请稍后重试', 409); }
    const request = this.performInteraction(bvid, action); this.interactions.set(bvid, { key, request });
    try { return await request; }
    finally { if (this.interactions.get(bvid)?.request === request) this.interactions.delete(bvid); }
  }

  private async performInteraction(bvid: string, action: EngagementAction): Promise<VideoEngagement> {
    const { jar, csrf } = await this.interactionCredentials(), before = await this.engagement(bvid);
    this.checkAccount(jar);
    const headers = { origin: 'https://www.bilibili.com', referer: `https://www.bilibili.com/video/${bvid}` };
    if (action.type === 'like') {
      if (before.liked === action.liked) return before;
      await this.prepareInteraction(jar);
      await this.transport.request(`${API}/x/web-interface/archive/like`, { method: 'POST', headers, form: { bvid, like: action.liked ? 1 : 2, csrf } });
    } else if (action.type === 'coin') {
      const video = await this.video(bvid); this.checkAccount(jar);
      if (action.coins > (video.interaction?.coinLimit ?? 2)) throw new BiliError('COIN_LIMIT', '对本稿件的投币枚数已用完或超过可投上限', 400);
      // The request specifies the desired total, so a retry cannot blindly add coins again.
      const multiply = Math.max(0, action.coins - before.coins);
      if (!multiply) return before;
      await this.prepareInteraction(jar);
      await this.transport.request(`${API}/x/web-interface/coin/add`, { method: 'POST', headers, form: { bvid, multiply, select_like: action.selectLike ? 1 : 0, csrf } });
    } else {
      const folders = await this.favoriteFolders(bvid), selected = new Set(action.folderIds);
      if ([...selected].some(id => !folders.some(folder => folder.id === id))) throw new BiliError('INVALID_FOLDER', '收藏夹已变化，请重新选择', 400);
      const add = folders.filter(folder => selected.has(folder.id) && !folder.selected).map(folder => folder.id), remove = folders.filter(folder => !selected.has(folder.id) && folder.selected).map(folder => folder.id);
      if (folders.some(folder => add.includes(folder.id) && folder.count >= (folder.capacity ?? Infinity))) throw new BiliError('FOLDER_FULL', '所选收藏夹已满，请选择其他收藏夹', 409);
      if (!add.length && !remove.length) return before;
      const video = await this.video(bvid); this.checkAccount(jar);
      await this.prepareInteraction(jar);
      await this.transport.request(`${API}/x/v3/fav/resource/deal`, { method: 'POST', headers, form: { rid: video.aid, type: 2, add_media_ids: add.length ? add.join(',') : undefined, del_media_ids: remove.length ? remove.join(',') : undefined, csrf } });
    }
    this.checkAccount(jar);
    return this.confirmInteraction(bvid, jar, async state => {
      if (action.type === 'like') return state.liked === action.liked;
      if (action.type === 'coin') return state.coins >= action.coins;
      const folders = await this.favoriteFolders(bvid), selected = new Set(action.folderIds);
      return state.favorited === Boolean(selected.size) && folders.every(folder => folder.selected === selected.has(folder.id));
    });
  }

  private async confirmInteraction(bvid: string, jar: BiliHttp['jar'], confirmed: (state: VideoEngagement) => boolean | Promise<boolean>): Promise<VideoEngagement> {
    for (const delay of [0, 150, 350]) {
      if (delay) await new Promise(resolve => setTimeout(resolve, delay));
      this.checkAccount(jar);
      try {
        const state = await this.engagement(bvid); this.checkAccount(jar);
        const matches = await confirmed(state); this.checkAccount(jar);
        if (matches) return state;
      } catch (error) { this.checkAccount(jar); if (error instanceof BiliError && error.status === 401) throw error; }
    }
    throw new BiliError('INTERACTION_UNCONFIRMED', '操作已提交，结果暂未确认，请先刷新状态，避免重复操作');
  }

  private async performTriple(bvid: string, jar: BiliHttp['jar']): Promise<TripleResult> {
    const cookies = await jar.getCookies(API);
    const csrf = cookies.find(cookie => cookie.key === 'bili_jct')?.value;
    if (!csrf || !cookies.some(cookie => cookie.key === 'SESSDATA')) throw new BiliError('LOGIN_REQUIRED', '登录 B 站后即可三连', 401);
    const before = await this.engagement(bvid);
    const complete = (state: VideoEngagement) => state.liked && state.coins > 0 && state.favorited;
    if (complete(before)) return { state: before, complete: true };
    if (this.transport.jar !== jar) throw new BiliError('LOGIN_REQUIRED', '账号状态已变化，请重试', 401);
    await this.prepareInteraction(jar);
    // One upstream action, with server-only CSRF. Never automatically retry a write.
    const result = await this.transport.request<RecordValue>(`${API}/x/web-interface/archive/like/triple`, { method: 'POST', form: { bvid, csrf }, headers: { origin: 'https://www.bilibili.com', referer: `https://www.bilibili.com/video/${bvid}` } });
    if (this.transport.jar !== jar) throw new BiliError('LOGIN_REQUIRED', '账号状态已变化，请检查三连结果', 401);
    if (typeof result?.like !== 'boolean' || typeof result?.coin !== 'boolean' || typeof result?.fav !== 'boolean') throw new BiliError('TRIPLE_UNCONFIRMED', '三连结果暂未确认，请先刷新状态，避免重复投币');
    let state: VideoEngagement;
    try { state = result.like && result.coin && result.fav ? await this.confirmInteraction(bvid, jar, complete) : await this.engagement(bvid); }
    catch (error) { if (error instanceof BiliError && error.status === 401) throw error; throw new BiliError('TRIPLE_UNCONFIRMED', '三连请求已提交，请先刷新状态确认结果，避免重复投币'); }
    if (this.transport.jar !== jar) throw new BiliError('LOGIN_REQUIRED', '账号状态已变化，请检查三连结果', 401);
    return { state, complete: complete(state) };
  }

  async search(keyword: string, type: 'video' | 'user', page = 1): Promise<SearchPage> {
    const term = clean(keyword, 200), pn = integer(page, '页码');
    if (!term) throw new BiliError('INVALID_INPUT', '请输入搜索内容', 400);
    if (type !== 'video' && type !== 'user') throw new BiliError('INVALID_INPUT', '搜索类型无效', 400);
    const data = await this.transport.request<RecordValue>(`${API}/x/web-interface/wbi/search/type`, { wbi: true, query: { keyword: term, search_type: type === 'video' ? 'video' : 'bili_user', page: pn, page_size: 30, order: type === 'video' ? 'totalrank' : '0' } });
    const results = array(data.result), pages = number(data.numPages), total = number(data.numResults);
    const videos = type === 'video' ? results.map(item => videoSummary(item)).filter((item): item is VideoSummary => Boolean(item)) : [];
    const users = type === 'user' ? results.filter(item => number(item.mid) > 0).map(item => ({ ...user({ mid: item.mid, name: item.uname, face: item.upic }), description: clean(item.usign, 3000), fans: number(item.fans) })) : [];
    return { videos: uniqueVideos(videos), users, page: pn, hasMore: pages ? pn < pages : total ? pn * number(data.pagesize, 30) < total : results.length >= 30 };
  }

  private async follows(mid: number): Promise<Set<number>> {
    const jar = this.transport.jar;
    if (this.followJar !== jar) { this.followCache = undefined; this.followRequests.clear(); this.followJar = jar; }
    if (this.followCache?.mid === mid && this.followCache.expires > Date.now()) return this.followCache.ids;
    const pending = this.followRequests.get(mid);
    if (pending) return pending;
    const request = this.loadFollows(mid, jar);
    this.followRequests.set(mid, request);
    try { return await request; }
    finally { if (this.followRequests.get(mid) === request) this.followRequests.delete(mid); }
  }

  private async loadFollows(mid: number, jar: BiliHttp['jar']): Promise<Set<number>> {
    const ids = new Set<number>();
    const read = async (pn: number) => {
      const data = await this.transport.request<RecordValue>(`${API}/x/relation/followings`, { query: { vmid: mid, pn, ps: 50, order: 'desc' } });
      if (!Array.isArray(data.list)) throw new BiliError('FOLLOW_LIST_INCOMPLETE', '关注列表未能完整读取，请稍后重试', 502);
      return { list: array(data.list), total: number(data.total) };
    };
    const add = (list: RecordValue[]) => { for (const item of list) if (number(item.mid)) ids.add(number(item.mid)); };
    const first = await read(1); add(first.list);
    const pages = Math.ceil(first.total / 50);
    if (pages > 200) throw new BiliError('FOLLOW_LIST_INCOMPLETE', '关注列表未能完整读取，请稍后重试', 502);
    if (pages) {
      // Verify the complete follow set with bounded concurrency, rather than serial round trips.
      for (let pn = 2; pn <= pages; pn += 3) {
        const batch = await Promise.all(Array.from({ length: Math.min(3, pages - pn + 1) }, (_, index) => read(pn + index)));
        for (const page of batch) add(page.list);
      }
    } else {
      let list = first.list, pn = 1;
      while (list.length >= 50) {
        if (++pn > 200) throw new BiliError('FOLLOW_LIST_INCOMPLETE', '关注列表未能完整读取，请稍后重试', 502);
        list = (await read(pn)).list; add(list);
      }
    }
    if (this.transport.jar === jar) this.followCache = { mid, ids, expires: Date.now() + 60_000 };
    return ids;
  }

  async following(cursor?: string): Promise<Page<VideoSummary>> {
    if (cursor && (cursor.length > 256 || !/^[\w:.-]+$/.test(cursor))) throw new BiliError('INVALID_INPUT', '分页标识无效', 400);
    // Check identity before any account-scoped work; a different account must never reuse another follow set.
    const identity = await this.transport.request<RecordValue>(`${API}/x/web-interface/nav`);
    const mid = number(identity.mid);
    if (!identity.isLogin || !mid) { this.followCache = undefined; throw new BiliError('LOGIN_REQUIRED', '请先登录以查看关注内容', 401); }
    const [followed, data] = await Promise.all([
      this.follows(mid),
      this.transport.request<RecordValue>(`${API}/x/polymer/web-dynamic/v1/feed/all`, { query: { type: 'video', ...(cursor ? { offset: cursor } : {}) } }),
    ]);
    if (!followed.size) return { items: [], hasMore: false };
    const items: VideoSummary[] = [];
    for (const item of array(data.items)) {
      const modules = object(item.modules), author = object(modules.module_author), major = object(object(modules.module_dynamic).major), archive = object(major.archive);
      // Only original video posts from an explicitly followed account are eligible.
      if (item.type !== 'DYNAMIC_TYPE_AV' || item.orig || major.type !== 'MAJOR_TYPE_ARCHIVE' || !followed.has(number(author.mid))) continue;
      if (archive.owner && number(object(archive.owner).mid) !== number(author.mid)) continue;
      const mapped = videoSummary({ ...archive, pubdate: archive.pubdate ?? author.pub_ts }, user(author));
      if (mapped) items.push(mapped);
    }
    const nextCursor = clean(data.offset, 256), hasMore = [true, 1, '1'].includes(data.has_more) && Boolean(nextCursor) && nextCursor !== cursor;
    return { items: uniqueVideos(items).sort((a, b) => b.publishedAt - a.publishedAt || a.bvid.localeCompare(b.bvid)), hasMore, ...(hasMore ? { nextCursor } : {}) };
  }

  async creator(mid: number): Promise<CreatorSummary> {
    const id = integer(mid, 'UP 主编号');
    const data = await this.transport.request<RecordValue>(`${API}/x/space/wbi/acc/info`, { wbi: true, query: { mid: id } });
    return { ...user(data), mid: id, description: clean(data.sign, 3000), ...(data.follower !== undefined ? { fans: number(data.follower) } : {}) };
  }

  async creatorVideos(mid: number, page = 1): Promise<Page<VideoSummary>> {
    const id = integer(mid, 'UP 主编号'), pn = integer(page, '页码');
    let owner: CreatorSummary, data: RecordValue;
    try {
      [owner, data] = await Promise.all([this.creator(id), this.transport.request<RecordValue>(`${API}/x/space/wbi/arc/search`, { wbi: true, headers: { referer: `https://space.bilibili.com/${id}/upload/video` }, query: { mid: id, pn, ps: 30, order: 'pubdate', tid: 0, keyword: '', platform: 'web', web_location: 1550101, order_avoided: true } })]);
    } catch (error) {
      if (error instanceof BiliError && error.code === '-101') throw new BiliError('LOGIN_REQUIRED', '请先登录以查看该 UP 主的投稿列表', 401);
      if (error instanceof BiliError && ['412', '-412', '-352'].includes(error.code)) throw new BiliError('RISK_CONTROL', 'B 站暂时限制了该 UP 主的投稿列表，请稍后或登录后重试', 429);
      throw error;
    }
    const list = array(object(data.list).vlist), total = number(object(data.page).count);
    const items = uniqueVideos(list.map(item => videoSummary(item, owner)).filter((item): item is VideoSummary => Boolean(item))).sort((a, b) => b.publishedAt - a.publishedAt);
    const hasMore = total ? pn * 30 < total : list.length >= 30;
    return { items, hasMore, ...(hasMore ? { nextPage: pn + 1 } : {}) };
  }

  async video(bvid: string): Promise<VideoDetail> {
    validBvid(bvid);
    const jar = this.transport.jar;
    if (this.videoJar !== jar) { this.videoCache.clear(); this.videoJar = jar; }
    const cached = this.videoCache.get(bvid);
    if (cached && cached.expires > Date.now()) return cached.request;
    const entry = { expires: Infinity, request: this.loadVideo(bvid) };
    this.videoCache.delete(bvid); this.videoCache.set(bvid, entry);
    // Detail availability may depend on the session; logout replaces the jar and invalidates it.
    while (this.videoCache.size > 64) this.videoCache.delete(this.videoCache.keys().next().value!);
    try {
      const detail = await entry.request;
      if (this.videoCache.get(bvid) === entry) {
        if (this.transport.jar === jar) entry.expires = Date.now() + 30_000;
        else this.videoCache.delete(bvid);
      }
      return detail;
    } catch (error) {
      if (this.videoCache.get(bvid) === entry) this.videoCache.delete(bvid);
      throw error;
    }
  }

  private async loadVideo(bvid: string): Promise<VideoDetail> {
    const data = await this.transport.request<RecordValue>(`${API}/x/web-interface/wbi/view`, { wbi: true, query: { bvid } });
    const stat = object(data.stat);
    return { bvid, aid: number(data.aid), title: clean(data.title, 1000), description: clean(data.desc, 10_000), cover: https(data.pic), owner: user(data.owner), parts: array(data.pages).map(part => ({ cid: number(part.cid), page: number(part.page), title: clean(part.part, 1000), duration: duration(part.duration) })).filter(part => part.cid > 0), publishedAt: number(data.pubdate), views: number(stat.view), interaction: { coinLimit: [1, 3].includes(number(data.copyright)) ? 2 : 1, likes: number(stat.like), coins: number(stat.coin), favorites: number(stat.favorite) } };
  }

  async playback(bvid: string, cid: number, quality = 127): Promise<PlaybackSource> {
    validBvid(bvid); integer(cid, '分 P 编号'); integer(quality, '画质');
    const [data, subtitles] = await Promise.all([
      this.transport.request<RecordValue>(`${API}/x/player/wbi/playurl`, { wbi: true, query: { bvid, cid, qn: quality, fnval: 4048, fnver: 0, fourk: 1 } }),
      this.subtitles(bvid, cid),
    ]);
    const dash = object(data.dash), videos = array(dash.video).filter(track => /^avc[13]\./i.test(String(track.codecs))), audios = array(dash.audio).filter(track => /^mp4a\./i.test(String(track.codecs)));
    const accepted = Array.isArray(data.accept_quality) ? data.accept_quality : [], labels = Array.isArray(data.accept_description) ? data.accept_description : [];
    const label = (id: number) => clean(labels[accepted.indexOf(id)] ?? array(data.support_formats).find(item => number(item.quality) === id)?.new_description ?? `${id}`, 100);
    if (videos.length) {
      const ids = [...new Set(videos.map(track => number(track.id)))].sort((a, b) => b - a);
      const selectedId = ids.find(id => id <= quality) ?? ids.at(-1);
      const selected = videos.filter(track => number(track.id) === selectedId).sort((a, b) => number(b.bandwidth) - number(a.bandwidth))[0];
      const video = this.dashTrack(selected), audio = audios.length ? this.dashTrack(audios.sort((a, b) => number(b.bandwidth) - number(a.bandwidth))[0]) : undefined;
      if (!video || (array(dash.audio).length > 0 && !audio)) throw new BiliError('UNSUPPORTED_PLAYBACK', '当前视频没有可用的 AVC/AAC 播放轨道', 422);
      return { cid, quality: video.id, qualities: ids.map(id => ({ id, label: label(id) })), duration: number(dash.duration, number(data.timelength) / 1000), video, ...(audio ? { audio } : {}), subtitles };
    }
    const segments = array(data.durl).map(segment => ({ url: https(segment.url), length: number(segment.length) })).filter(segment => segment.url && segment.length > 0);
    const progressiveMp4 = /mp4/i.test(String(data.format ?? '')) || segments.every(segment => /\.mp4(?:$|\?)/i.test(segment.url));
    if (!segments.length || !progressiveMp4) throw new BiliError('UNSUPPORTED_PLAYBACK', '当前视频没有浏览器支持的 AVC/AAC 播放流', 422);
    // durl is returned only when upstream actually supplied progressive media, never inferred from DASH.
    return { cid, quality: number(data.quality, quality), qualities: accepted.map((id: unknown) => ({ id: number(id), label: label(number(id)) })), duration: number(data.timelength) / 1000, segments, subtitles };
  }

  private dashTrack(raw: RecordValue): DashTrack | undefined {
    const baseUrl = https(raw.baseUrl ?? raw.base_url), segment = object(raw.SegmentBase ?? raw.segment_base);
    const initialization = clean(segment.Initialization ?? segment.initialization, 100), indexRange = clean(segment.indexRange ?? segment.index_range, 100);
    if (!baseUrl || !/^\d+-\d+$/.test(initialization) || !/^\d+-\d+$/.test(indexRange)) return undefined;
    return { id: number(raw.id), baseUrl, backupUrl: (Array.isArray(raw.backupUrl ?? raw.backup_url) ? raw.backupUrl ?? raw.backup_url : []).map(https).filter(Boolean), mimeType: clean(raw.mimeType ?? raw.mime_type, 100), codecs: clean(raw.codecs, 100), bandwidth: number(raw.bandwidth), ...(raw.width ? { width: number(raw.width) } : {}), ...(raw.height ? { height: number(raw.height) } : {}), ...(raw.frameRate || raw.frame_rate ? { frameRate: clean(raw.frameRate ?? raw.frame_rate, 40) } : {}), segmentBase: { initialization, indexRange } };
  }

  private async subtitles(bvid: string, cid: number): Promise<Subtitle[]> {
    try {
      const data = await this.transport.request<RecordValue>(`${API}/x/player/wbi/v2`, { wbi: true, query: { bvid, cid } });
      return array(object(data.subtitle).subtitles).map(item => ({ id: clean(item.id_str ?? item.id, 100), lang: clean(item.lan, 40), label: clean(item.lan_doc, 100), url: https(item.subtitle_url) })).filter(item => item.url);
    } catch { return []; } // Subtitle availability is optional and must not prevent video playback.
  }

  async danmaku(cid: number): Promise<Danmaku[]> {
    const id = integer(cid, '分 P 编号'), response = await this.transport.fetchWithCookies(`${API}/x/v1/dm/list.so?oid=${id}`, { signal: AbortSignal.timeout(20_000) });
    if (!response.ok) throw new BiliError('DANMAKU_UNAVAILABLE', '弹幕暂时无法读取', 502);
    const xml = await response.text();
    if (xml.length > 8_000_000 || XMLValidator.validate(xml) !== true) throw new BiliError('UPSTREAM_INVALID_DATA', '弹幕数据无效', 502);
    const parsed = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@_', parseTagValue: false, processEntities: false }).parse(xml);
    const raw = object(parsed.i).d, list = Array.isArray(raw) ? raw : raw ? [raw] : [];
    return list.slice(0, 10_000).map((item: RecordValue) => {
      const attrs = String(item['@_p'] ?? '').split(','), color = Math.min(0xffffff, number(attrs[3], 0xffffff));
      return { text: clean(item['#text'], 300), time: number(attrs[0]), mode: number(attrs[1], 1), fontSize: Math.min(64, Math.max(12, number(attrs[2], 25))), color: `#${Math.floor(color).toString(16).padStart(6, '0')}` };
    }).filter((item: Danmaku) => item.text && item.time < 86_400 && [1, 4, 5, 6].includes(item.mode));
  }

  async comments(aid: number, page = 1, cursor?: string): Promise<Page<Comment>> {
    const id = integer(aid, '稿件编号'), pn = integer(page, '页码');
    if ((pn > 1 && !cursor) || (cursor !== undefined && (cursor.length > 8192 || /[\u0000-\u001f]/.test(cursor)))) throw new BiliError('INVALID_INPUT', '评论翻页标识无效，请重新加载评论', 400);
    const data = await this.transport.request<RecordValue>(`${API}/x/v2/reply/wbi/main`, { wbi: true, query: { type: 1, oid: id, mode: 2, pagination_str: JSON.stringify({ offset: cursor ?? '' }), plat: 1, web_location: '1315875' } });
    const paging = object(data.cursor), isEnd = [true, 1, '1'].includes(paging.is_end);
    if (!Array.isArray(data.replies) && !(isEnd && number(paging.all_count) === 0)) throw new BiliError('COMMENTS_UNAVAILABLE', clean(object(data.control).show_text, 200) || '评论暂时无法读取，请登录或稍后重试', 502);
    const map = (item: RecordValue, nested = false): Comment => ({ id: clean(item.rpid_str ?? item.rpid, 40), user: user(item.member), text: clean(object(item.content).message, 6000), createdAt: number(item.ctime), likes: number(item.like), replies: nested ? [] : array(item.replies).slice(0, 20).map(reply => map(reply, true)) });
    const items = array(data.replies).map(item => map(item)), rawCursor = object(paging.pagination_reply).next_offset;
    const nextCursor = typeof rawCursor === 'string' && rawCursor.length <= 8192 && !/[\u0000-\u001f]/.test(rawCursor) ? rawCursor : '';
    if (!isEnd && (!items.length || !nextCursor)) throw new BiliError('COMMENTS_UNAVAILABLE', '评论分页数据不完整，请稍后重试', 502);
    const hasMore = !isEnd && items.length > 0 && Boolean(nextCursor);
    return { items, hasMore, ...(hasMore ? { nextPage: pn + 1, nextCursor } : {}) };
  }

  async resolve(input: string): Promise<string> {
    const value = input.trim();
    if (value.length > 2048) throw new BiliError('INVALID_INPUT', '链接过长', 400);
    if (BVID.test(value)) return `/video/${value}`;
    if (/^av\d+$/i.test(value)) return this.resolveAid(value.slice(2));
    let url: URL;
    try { url = new URL(value); } catch {
      const term = clean(value, 200);
      if (!term || /^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(value)) throw new BiliError('INVALID_INPUT', '请输入搜索词、BV 号、av 号或 B 站链接', 400);
      return `/search?keyword=${encodeURIComponent(term)}&type=video&page=1`;
    }
    for (let hop = 0; hop < 5; hop++) {
      this.assertBiliLink(url);
      if (url.hostname === 'b23.tv' || url.hostname === 'www.b23.tv') {
        const response = await this.transport.fetchWithCookies(url.href, { method: 'GET', redirect: 'manual', signal: AbortSignal.timeout(20_000) });
        const location = response.headers.get('location');
        await response.body?.cancel();
        if (response.status < 300 || response.status >= 400 || !location) throw new BiliError('LINK_UNRESOLVED', '短链接暂时无法解析', 422);
        url = new URL(location, url); continue;
      }
      if (['bilibili.com', 'www.bilibili.com', 'm.bilibili.com'].includes(url.hostname) && url.pathname === '/') return '/';
      const video = url.pathname.match(/^\/video\/(BV[0-9A-Za-z]{10}|[aA][vV]\d+)(?:\/|$)/);
      if (video) {
        const route = video[1].startsWith('BV') ? `/video/${video[1]}` : await this.resolveAid(video[1].slice(2));
        const part = Number(url.searchParams.get('p'));
        return Number.isSafeInteger(part) && part > 1 && part <= 1000 ? `${route}?p=${part}` : route;
      }
      if (url.hostname === 'space.bilibili.com' && /^\/\d+\/?$/.test(url.pathname)) return `/creator/${integer(url.pathname.replace(/\//g, ''), 'UP 主编号')}`;
      const keyword = clean(url.searchParams.get('keyword'), 200);
      if (url.hostname === 'search.bilibili.com' && keyword) return `/search?keyword=${encodeURIComponent(keyword)}&type=video&page=1`;
      throw new BiliError('UNSUPPORTED_LINK', '暂不支持此类 B 站链接，请粘贴普通视频链接', 422);
    }
    throw new BiliError('LINK_UNRESOLVED', '短链接跳转次数过多', 422);
  }

  private assertBiliLink(url: URL): void {
    if (url.protocol !== 'https:' || !LINK_HOSTS.has(url.hostname) || url.username || url.password || (url.port && url.port !== '443')) throw new BiliError('UNSAFE_URL', '只允许 HTTPS 的 B 站链接', 400);
  }
  private async resolveAid(aid: string): Promise<string> {
    const data = await this.transport.request<RecordValue>(`${API}/x/web-interface/wbi/view`, { wbi: true, query: { aid: integer(aid, 'av 号') } });
    return `/video/${validBvid(typeof data.bvid === 'string' ? data.bvid.trim() : '')}`;
  }
}
