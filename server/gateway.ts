import { XMLParser, XMLValidator } from 'fast-xml-parser';
import type { CoinInfo, CollectionKind, CollectionPage, Comment, CommentReplyPage, CommentSubmission, CreatorCollection, CreatorSummary, Danmaku, EngagementAction, FavoriteFolder, HistoryItem, Page, Quality, SearchPage, Subtitle, TripleResult, User, VideoDynamic, VideoDetail, VideoEngagement, VideoPart, VideoSearchOrder, VideoSummary } from '../shared/types.js';
import type { DynamicLikeState, WatchLaterItem, WatchLaterPage } from '../shared/types.js';
import { BiliError, type BiliHttp } from './transport.js';

type RecordValue = Record<string, any>;
const API = 'https://api.bilibili.com';
const BVID = /^BV[0-9A-Za-z]{10}$/;
const WATCH_LATER = `${API}/x/v2/history/toview`;
const WATCH_LATER_PAGE_SIZE = 20;
const WATCH_LATER_HEADERS = { referer: 'https://www.bilibili.com/watchlater/list', origin: 'https://www.bilibili.com' };
const DYNAMIC_LIKE_REFRESH_WINDOW = 60_000;
const LIKE_CONFIRM_DELAYS = [0, 250, 500, 1000];
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
function dynamicLike(value: unknown): DynamicLikeState | undefined {
  const { count, status } = object(value);
  if (typeof count !== 'number' || !Number.isSafeInteger(count) || count < 0 || ![true, false, 0, 1].includes(status)) return;
  return { liked: status === true || status === 1, likes: count };
}
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

const COMMENT_ID = /^[1-9]\d{0,39}$/;
type CommentThread = { oid: number | string; type: number };
type CommentWriteTarget = CommentThread & { referer: string };
function replyIdentity(value: RecordValue, key: string): string {
  const id = value[`${key}_str`] ?? value[key];
  return typeof id === 'string' ? id : Number.isSafeInteger(id) ? String(id) : '';
}
function mapComment(item: RecordValue, nested = false): Comment {
  const content = object(item.content);
  const text = clean(content.message, 6000);
  const emotes = Object.entries(object(content.emote)).flatMap(([token, emote]) => {
    if (!/^\[[^\[\]\r\n]{1,100}\]$/u.test(token) || !text.includes(token)) return [];
    const url = https(object(emote).url);
    return url ? [[token, url] as const] : [];
  });
  const people = new Map<string, number>(array(content.members).map(member => {
    const { name, mid } = user(member);
    return [name, mid];
  }));
  for (const [name, mid] of Object.entries(object(content.at_name_to_mid))) people.set(clean(name, 80), number(mid));
  const mentions = [...people].filter(([name, mid]) => name && Number.isSafeInteger(mid) && mid > 0)
    .map(([name, mid]) => ({ mid, name }));
  return {
    id: replyIdentity(item, 'rpid'), user: user(item.member), text,
    createdAt: number(item.ctime), likes: number(item.like),
    ...(typeof item.action === 'number' ? { liked: item.action === 1 } : {}),
    ...(mentions.length ? { mentions } : {}),
    ...(emotes.length ? { emotes: Object.fromEntries(emotes) } : {}),
    replyCount: nested ? 0 : number(item.rcount),
    replies: nested ? [] : array(item.replies).slice(0, 20).map(reply => mapComment(reply, true)),
  };
}
function commentMessage(input: CommentSubmission) {
  const { text, root, parent, mentions } = input ?? {};
  if (typeof text !== 'string' || !text.trim() || text.length > 1000 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(text)) {
    throw new BiliError('INVALID_COMMENT', '请输入 1 至 1000 字的评论。', 400);
  }
  if ((root !== undefined && (typeof root !== 'string' || !COMMENT_ID.test(root))) ||
      (parent !== undefined && (!root || typeof parent !== 'string' || !COMMENT_ID.test(parent)))) {
    throw new BiliError('INVALID_COMMENT', '回复目标无效，请重新选择。', 400);
  }
  const names = new Map<string, number>();
  if (mentions !== undefined) {
    if (!Array.isArray(mentions) || mentions.length > 20) throw new BiliError('INVALID_MENTION', '@ 用户列表无效。', 400);
    for (const mention of mentions) {
      const { mid, name } = object(mention);
      if (!Number.isSafeInteger(mid) || mid <= 0 || typeof name !== 'string' ||
          !name || name !== clean(name, 80) || /[\r\n@]/.test(name) ||
          !text.split(`@${name}`).slice(1).some(suffix => !suffix || /^\s/.test(suffix)) ||
          (names.has(name) && names.get(name) !== mid)) throw new BiliError('INVALID_MENTION', '@ 用户已变化，请重新选择。', 400);
      names.set(name, mid);
    }
  }
  return { text, root, parent: parent ?? root, names };
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

interface WatchLaterSession {
  jar: BiliHttp['jar'];
  mid: number;
  membership?: { aids: Set<number>; expires: number };
  reading?: Promise<Set<number>>;
  writes?: Promise<number[]>;
  pending: Map<string, Promise<number[]>>;
}

export class BiliGateway {
  private followCache?: { expires: number; mid: number; ids: Set<number> };
  private readonly followRequests = new Map<number, Promise<Set<number>>>();
  private followJar?: BiliHttp['jar'];
  private readonly videoCache = new Map<string, { expires: number; request: Promise<VideoDetail> }>();
  private videoJar?: BiliHttp['jar'];
  private tripleJar?: BiliHttp['jar'];
  private readonly dynamicWrites = new WeakMap<BiliHttp['jar'], Map<string, { mid: number; liked: boolean; request: Promise<VideoDynamic> }>>();
  private readonly dynamicConfirmations = new WeakMap<BiliHttp['jar'], Map<string, { mid: number; state: DynamicLikeState; expires: number }>>();
  private readonly commentWrites = new WeakMap<BiliHttp['jar'], Set<string>>();
  private readonly triples = new Map<string, Promise<TripleResult>>();
  private readonly interactions = new Map<string, { key: string; request: Promise<VideoEngagement> }>();
  private readonly folderCreations = new WeakMap<BiliHttp['jar'], Map<string, Promise<FavoriteFolder>>>();
  private readonly watchLaterSessions = new WeakMap<BiliHttp['jar'], WatchLaterSession>();
  constructor(private readonly transport: BiliHttp) {}

  async watchLater(page: number, mid: number): Promise<WatchLaterPage> {
    const session = await this.watchLaterSession(mid);
    await session.writes?.catch(() => {});
    return this.readWatchLaterPage(integer(page, '页码'), session);
  }

  async watchLaterMembership(mid: number, refresh = false): Promise<{ aids: number[]; accountMid: number }> {
    const session = await this.watchLaterSession(mid);
    await session.writes?.catch(() => {});
    const cached = session.membership;
    let aids: Set<number>;
    if (!refresh && cached && cached.expires > Date.now()) aids = cached.aids;
    else {
      session.reading ??= this.readWatchLaterAids(session).finally(() => { session.reading = undefined; });
      aids = await session.reading;
    }
    await this.watchLaterCredentials(session);
    return { aids: [...aids], accountMid: mid };
  }

  async setWatchLater(aid: number, saved: boolean, mid: number): Promise<{ saved: boolean; accountMid: number }> {
    if (typeof saved !== 'boolean') throw new BiliError('INVALID_INPUT', '稍后再看状态无效', 400);
    await this.writeWatchLater([integer(aid, '视频编号')], saved, mid, false);
    return { saved, accountMid: mid };
  }

  async removeWatchLater(aids: number[], mid: number): Promise<{ removed: number[]; accountMid: number }> {
    if (!Array.isArray(aids) || !aids.length || aids.some(aid => !Number.isSafeInteger(aid) || aid <= 0)) {
      throw new BiliError('INVALID_INPUT', '请选择要移出的有效视频', 400);
    }
    const removed = await this.writeWatchLater([...new Set(aids)].sort((a, b) => a - b), false, mid, true);
    return { removed, accountMid: mid };
  }

  private async watchLaterSession(mid: number): Promise<WatchLaterSession> {
    integer(mid, '账号编号');
    const jar = this.transport.jar;
    let session = this.watchLaterSessions.get(jar);
    if (session?.mid !== mid) {
      const candidate = { jar, mid, pending: new Map<string, Promise<number[]>>() };
      await this.watchLaterCredentials(candidate);
      session = this.watchLaterSessions.get(jar);
      if (session?.mid !== mid) {
        session = candidate;
        this.watchLaterSessions.set(jar, session);
      }
    } else await this.watchLaterCredentials(session);
    return session;
  }

  private async watchLaterCredentials({ jar, mid }: WatchLaterSession) {
    const cookies = await jar.getCookies(API);
    const identity = cookies.find(cookie => cookie.key === 'DedeUserID')?.value;
    if (jar !== this.transport.jar || (identity && identity !== String(mid))) {
      throw new BiliError('ACCOUNT_CHANGED', 'B 站账号已切换，请重新打开稍后再看', 409);
    }
    if (!cookies.some(cookie => cookie.key === 'SESSDATA' && cookie.value)) {
      throw new BiliError('LOGIN_REQUIRED', '登录 B 站后即可使用稍后再看', 401);
    }
    if (!identity) {
      throw new BiliError('LOGIN_REQUIRED', 'B 站账号信息不完整，请重新登录', 401);
    }
    return cookies.find(cookie => cookie.key === 'bili_jct')?.value;
  }

  private async readWatchLaterPage(page: number, session: WatchLaterSession, signal?: AbortSignal): Promise<WatchLaterPage> {
    const { jar, mid } = session;
    const data = await this.transport.request<RecordValue>(`${WATCH_LATER}/web`, {
      query: { pn: page, ps: WATCH_LATER_PAGE_SIZE, asc: 0, viewed: 0, need_split: 1 },
      headers: WATCH_LATER_HEADERS, sessionJar: jar, sessionMid: mid, signal,
    });
    await this.watchLaterCredentials(session);
    const total = data?.count, list = data?.list === null && total === 0 ? [] : data?.list;
    if (!Number.isSafeInteger(total) || total < 0 || !Array.isArray(list)) {
      throw new BiliError('WATCH_LATER_UNAVAILABLE', 'B 站稍后再看列表暂时无法完整读取，请重试');
    }
    const items: WatchLaterItem[] = [];
    for (const raw of list) {
      const entry = object(raw), aid = Number(entry.aid);
      if (aid === -1 || aid === 0) continue; // B 站插入的列表分隔与占位项。
      if (!Number.isSafeInteger(aid) || aid < 0) throw new BiliError('WATCH_LATER_UNAVAILABLE', 'B 站稍后再看条目信息不完整，请重试');
      const summary = videoSummary(entry), progress = Number(entry.progress);
      items.push({
        ...(summary ?? { bvid: '', aid, title: clean(entry.title, 1000), cover: https(entry.pic), duration: duration(entry.duration), publishedAt: number(entry.pubdate), owner: user(entry.owner) }),
        title: clean(entry.translated_title, 1000) || summary?.title || clean(entry.title, 1000) || '失效视频',
        aid, cid: number(entry.cid), addedAt: number(entry.add_at ?? entry.add_time),
        progress: progress === -1 ? -1 : number(progress),
        unavailable: !summary || entry.is_expired === true || (typeof entry.state === 'number' && entry.state < 0),
      });
    }
    if (!items.length && (page - 1) * WATCH_LATER_PAGE_SIZE < total) {
      throw new BiliError('WATCH_LATER_UNAVAILABLE', 'B 站稍后再看列表暂时无法完整读取，请重试');
    }
    const hasMore = page * WATCH_LATER_PAGE_SIZE < total;
    return { items, total, hasMore, ...(hasMore ? { nextPage: page + 1 } : {}), accountMid: mid };
  }

  private async readWatchLaterAids(session: WatchLaterSession): Promise<Set<number>> {
    const signal = AbortSignal.timeout(20_000), aids = new Set<number>();
    let next: number | undefined = 1, total: number | undefined;
    while (next !== undefined) {
      const page = await this.readWatchLaterPage(next, session, signal);
      if (total !== undefined && total !== page.total) {
        throw new BiliError('WATCH_LATER_CHANGED', 'B 站稍后再看列表刚刚发生变化，请刷新', 409);
      }
      total = page.total;
      for (const item of page.items) {
        if (aids.has(item.aid)) throw new BiliError('WATCH_LATER_CHANGED', 'B 站稍后再看列表刚刚发生变化，请刷新', 409);
        aids.add(item.aid);
      }
      next = page.nextPage;
    }
    session.membership = { aids, expires: Date.now() + 10_000 };
    return aids;
  }

  private async writeWatchLater(aids: number[], saved: boolean, mid: number, bulk: boolean): Promise<number[]> {
    const session = await this.watchLaterSession(mid), { jar } = session;
    const key = `${saved}:${aids.join(',')}`;
    const pending = session.pending.get(key);
    if (pending) return pending;
    const task = Promise.resolve(session.writes).catch(() => {}).then(async () => {
      await session.reading?.catch(() => {});
      session.membership = undefined;
      const before = await this.readWatchLaterAids(session);
      const changes = aids.filter(aid => before.has(aid) !== saved);
      if (!changes.length) return aids;
      await this.transport.ensureDeviceCookies();
      const csrf = await this.watchLaterCredentials(session);
      if (!csrf) throw new BiliError('LOGIN_REQUIRED', '登录凭据不完整，请重新登录后操作稍后再看', 401);
      session.membership = undefined;
      const endpoint = bulk && changes.length > 1 ? 'v2/dels' : saved ? 'add' : 'del';
      let verify = endpoint === 'v2/dels';
      try {
        await this.transport.request(`${WATCH_LATER}/${endpoint}`, {
          method: 'POST', sessionJar: jar, sessionMid: mid, headers: WATCH_LATER_HEADERS,
          ...(endpoint === 'v2/dels'
            ? { multipartForm: { resources: changes.join(','), csrf } }
            : { form: { aid: changes[0], csrf } }),
        });
      } catch (error) {
        if (!(error instanceof BiliError) || (!['UPSTREAM_UNAVAILABLE', 'INVALID_RESPONSE'].includes(error.code) &&
            !/^5\d{2}$/.test(error.code))) throw error;
        verify = true;
      }
      await this.watchLaterCredentials(session);
      if (verify) {
        const confirmed = await this.readWatchLaterAids(session).catch(() => undefined);
        if (!confirmed || changes.some(aid => confirmed.has(aid) !== saved)) {
          throw new BiliError('WATCH_LATER_UNCONFIRMED', '暂时无法确认操作结果，请刷新稍后再看列表', 409);
        }
      } else {
        const current = new Set(before);
        for (const aid of changes) if (saved) current.add(aid); else current.delete(aid);
        session.membership = { aids: current, expires: Date.now() + 10_000 };
      }
      return aids;
    });
    session.pending.set(key, task);
    session.writes = task;
    try { return await task; }
    finally {
      if (session.pending.get(key) === task) session.pending.delete(key);
      if (session.writes === task) session.writes = undefined;
    }
  }

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

  async search(keyword: string, type: 'video' | 'user', page = 1, order: VideoSearchOrder = 'totalrank'): Promise<SearchPage> {
    const term = clean(keyword, 200), pn = integer(page, '页码');
    if (!term) throw new BiliError('INVALID_INPUT', '请输入搜索内容', 400);
    if (type !== 'video' && type !== 'user') throw new BiliError('INVALID_INPUT', '搜索类型无效', 400);
    const data = await this.transport.request<RecordValue>(`${API}/x/web-interface/wbi/search/type`, { wbi: true, query: { keyword: term, search_type: type === 'video' ? 'video' : 'bili_user', page: pn, page_size: 30, order: type === 'video' ? order : '0' } });
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
    const jar = this.transport.jar;
    const identity = await this.transport.request<RecordValue>(`${API}/x/web-interface/nav`, { sessionJar: jar });
    this.checkAccount(jar);
    const mid = number(identity.mid);
    if (!identity.isLogin || !mid) { this.followCache = undefined; throw new BiliError('LOGIN_REQUIRED', '请先登录以查看关注内容', 401); }
    const [followed, data] = await Promise.all([
      this.follows(mid),
      this.transport.request<RecordValue>(`${API}/x/polymer/web-dynamic/v1/feed/all`, { query: { type: 'video', ...(cursor ? { offset: cursor } : {}) }, sessionJar: jar }),
    ]);
    this.checkAccount(jar);
    if (!followed.size) return { items: [], hasMore: false };
    const items: VideoSummary[] = [];
    for (const item of array(data.items)) {
      const modules = object(item.modules), author = object(modules.module_author), major = object(object(modules.module_dynamic).major), archive = object(major.archive);
      // Only original video posts from an explicitly followed account are eligible.
      if (item.type !== 'DYNAMIC_TYPE_AV' || item.orig || major.type !== 'MAJOR_TYPE_ARCHIVE' || !followed.has(number(author.mid))) continue;
      if (archive.owner && number(object(archive.owner).mid) !== number(author.mid)) continue;
      const mapped = videoSummary({ ...archive, pubdate: archive.pubdate ?? author.pub_ts }, user(author));
      if (mapped) {
        const dynamicId = typeof item.id_str === 'string' && /^[1-9]\d{0,31}$/.test(item.id_str) ? item.id_str : undefined;
        const stats = object(modules.module_stat), like = dynamicLike(stats.like);
        items.push({
          ...mapped,
          ...(dynamicId ? { dynamicId, dynamicComments: number(object(stats.comment).count) } : {}),
          ...(dynamicId && like ? { dynamicLikes: like.likes, dynamicLiked: like.liked } : {}),
        });
      }
    }
    const nextCursor = clean(data.offset, 256), hasMore = [true, 1, '1'].includes(data.has_more) && Boolean(nextCursor) && nextCursor !== cursor;
    const sorted = uniqueVideos(items).sort((a, b) => b.publishedAt - a.publishedAt || a.bvid.localeCompare(b.bvid));
    const reconciled = await Promise.all(sorted.map(video => this.reconcileFollowingLike(video, jar, mid)));
    this.checkAccount(jar);
    return { items: reconciled, hasMore, ...(hasMore ? { nextCursor } : {}) };
  }

  private async reconcileFollowingLike(video: VideoSummary, jar: BiliHttp['jar'], mid: number): Promise<VideoSummary> {
    const id = video.dynamicId;
    if (!id) return video;
    const confirmations = this.dynamicConfirmations.get(jar);
    const active = this.dynamicWrites.get(jar)?.get(id);
    if (active?.mid === mid) {
      try {
        const result = await active.request;
        return { ...video, dynamicLiked: result.liked, dynamicLikes: result.likes };
      } catch { this.checkAccount(jar); }
    }
    const recent = confirmations?.get(id);
    if (!recent || recent.mid !== mid) return video;
    if (recent.state.liked === video.dynamicLiked && (recent.state.likes === video.dynamicLikes ||
        (video.dynamicLikes !== undefined && recent.expires <= Date.now()))) return video;
    try {
      const result = await this.dynamic(id);
      this.checkAccount(jar);
      if (confirmations?.get(id) === recent) confirmations.set(id, { ...recent, state: { liked: result.liked, likes: result.likes } });
    } catch (error) {
      this.checkAccount(jar);
      if (error instanceof BiliError && error.status === 401) throw error;
    }
    const latest = confirmations?.get(id);
    const state = latest?.mid === mid ? latest.state : recent.state;
    return { ...video, dynamicLiked: state.liked, dynamicLikes: state.likes };
  }

  private async dynamicItem(id: string): Promise<RecordValue> {
    if (!/^[1-9]\d{0,31}$/.test(id)) throw new BiliError('INVALID_INPUT', '动态编号无效', 400);
    const jar = this.transport.jar;
    await this.transport.ensureDeviceCookies(); this.checkAccount(jar);
    const data = await this.transport.request<RecordValue>(`${API}/x/polymer/web-dynamic/v1/detail`, { query: { id, platform: 'web', features: 'itemOpusStyle,opusBigCover,ugcDelete' }, sessionJar: jar });
    this.checkAccount(jar);
    const item = object(data.item);
    if (item.id_str !== id) throw new BiliError('INVALID_RESPONSE', '动态内容与当前编号不一致');
    return item;
  }

  async dynamic(id: string): Promise<VideoDynamic> {
    const item = await this.dynamicItem(id);
    const modules = object(item.modules), author = user(modules.module_author), content = object(modules.module_dynamic), major = object(content.major), archive = object(major.archive);
    if (item.type !== 'DYNAMIC_TYPE_AV' || item.orig || major.type !== 'MAJOR_TYPE_ARCHIVE') throw new BiliError('DYNAMIC_UNSUPPORTED', '当前网页暂时无法完整展示此类型动态', 502);
    if (archive.owner && number(object(archive.owner).mid) !== author.mid) throw new BiliError('INVALID_RESPONSE', '动态作者与视频归属不一致');
    const video = videoSummary({ ...archive, pubdate: archive.pubdate ?? object(modules.module_author).pub_ts }, author), stats = object(modules.module_stat), like = dynamicLike(stats.like);
    if (!video || !like) throw new BiliError('DYNAMIC_UNAVAILABLE', '动态或点赞状态暂时无法确认，请重试', 502);
    return { id, author, video, publishedAt: number(object(modules.module_author).pub_ts), action: clean(object(modules.module_author).pub_action), text: clean(object(content.desc).text, 10000), comments: number(object(stats.comment).count), ...like };
  }

  async setDynamicLike(id: string, liked: boolean): Promise<VideoDynamic> {
    if (!/^[1-9]\d{0,31}$/.test(id) || typeof liked !== 'boolean') throw new BiliError('INVALID_INPUT', '动态点赞参数无效', 400);
    const { jar, csrf, mid } = await this.interactionCredentials();
    this.checkAccount(jar);
    let writes = this.dynamicWrites.get(jar);
    if (!writes) { writes = new Map(); this.dynamicWrites.set(jar, writes); }
    const active = writes.get(id);
    if (active) {
      if (active.liked !== liked) throw new BiliError('INTERACTION_BUSY', '该动态正在处理，请稍候', 409);
      return active.request;
    }
    const request = (async () => {
      const before = await this.dynamic(id); this.checkAccount(jar);
      if (before.liked === liked) return before;
      let writeError: unknown;
      try { await this.transport.request(`${API}/x/dynamic/feed/dyn/thumb`, { method: 'POST', sessionJar: jar, sessionMid: mid || undefined, query: { csrf }, json: { dyn_id_str: id, up: liked ? 1 : 2 }, headers: { origin: 'https://www.bilibili.com', referer: `https://t.bilibili.com/${id}` } }); }
      catch (error) {
        this.checkAccount(jar);
        if (error instanceof BiliError && (error.status === 401 || error.code === 'ACCOUNT_CHANGED')) throw error;
        writeError = error;
      }
      const delays = writeError ? [0, 150, 150] : LIKE_CONFIRM_DELAYS;
      let confirmed: VideoDynamic | undefined;
      let readError: unknown;
      for (const delay of delays) {
        if (delay) await new Promise(resolve => setTimeout(resolve, delay));
        this.checkAccount(jar);
        try {
          const after = await this.dynamic(id);
          this.checkAccount(jar);
          if (after.liked !== liked) continue;
          if (after.likes !== before.likes) return after;
          confirmed = after;
        } catch (error) { this.checkAccount(jar); readError ??= error; }
      }
      if (confirmed) return confirmed;
      if (writeError) throw writeError;
      if (readError) throw readError;
      throw new BiliError('DYNAMIC_LIKE_UNCONFIRMED', '点赞结果暂未确认，请刷新动态后再操作');
    })().then(result => {
      this.checkAccount(jar);
      let confirmations = this.dynamicConfirmations.get(jar);
      if (!confirmations) this.dynamicConfirmations.set(jar, confirmations = new Map());
      confirmations.delete(id);
      confirmations.set(id, { mid, state: { liked: result.liked, likes: result.likes }, expires: Date.now() + DYNAMIC_LIKE_REFRESH_WINDOW });
      if (confirmations.size > 32) confirmations.delete(confirmations.keys().next().value!);
      return result;
    });
    writes.set(id, { mid, liked, request });
    try { return await request; } finally { if (writes.get(id)?.request === request) writes.delete(id); }
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
    const shares = stat.share;
    return { bvid, aid: number(data.aid), title: clean(data.title, 1000), description: clean(data.desc, 10_000), cover: https(data.pic), owner: user(data.owner), parts: array(data.pages).map(part => ({ cid: number(part.cid), page: number(part.page), title: clean(part.part, 1000), duration: duration(part.duration) })).filter(part => part.cid > 0), publishedAt: number(data.pubdate), views: number(stat.view), interaction: { coinLimit: [1, 3].includes(number(data.copyright)) ? 2 : 1, likes: number(stat.like), coins: number(stat.coin), favorites: number(stat.favorite), ...(typeof shares === "number" && Number.isSafeInteger(shares) && shares >= 0 ? { shares } : {}) } };
  }

  async playback(bvid: string, cid: number, quality = 127): Promise<PlaybackSource> {
    validBvid(bvid); integer(cid, '分 P 编号'); integer(quality, '画质');
    // Optional metadata has its own route: a slow subtitle service must not gate the first frame.
    const jar = this.transport.jar;
    const read = async (fnval: number) => {
      if (this.transport.jar !== jar) throw new BiliError('LOGIN_REQUIRED', '账号状态已变化，请重试', 401);
      const data = await this.transport.request<RecordValue>(`${API}/x/player/wbi/playurl`, { wbi: true, query: { bvid, cid, qn: quality, fnval, fnver: 0, fourk: 1 } });
      if (this.transport.jar !== jar) throw new BiliError('LOGIN_REQUIRED', '账号状态已变化，请重试', 401);
      return data;
    };
    const data = await read(4048);
    try { return this.playbackSource(data, cid, quality); }
    catch (error) { if (!(error instanceof BiliError) || error.code !== 'UNSUPPORTED_PLAYBACK') throw error; }
    // A successful but unusable DASH response may still have an official progressive MP4.
    // Never retry permission, risk-control or network failures, or construct a media URL.
    return this.playbackSource(await read(1), cid, quality);
  }

  private playbackSource(data: RecordValue, cid: number, quality: number): PlaybackSource {
    const subtitles: Subtitle[] = [];
    const dash = object(data.dash);
    const videos = array(dash.video).filter(track => /^avc[13]\./i.test(String(track.codecs))).map(track => this.dashTrack(track)).filter((track): track is DashTrack => Boolean(track));
    const audios = array(dash.audio).filter(track => /^mp4a\./i.test(String(track.codecs))).map(track => this.dashTrack(track)).filter((track): track is DashTrack => Boolean(track));
    const accepted = Array.isArray(data.accept_quality) ? data.accept_quality : [], labels = Array.isArray(data.accept_description) ? data.accept_description : [];
    const label = (id: number) => clean(labels[accepted.indexOf(id)] ?? array(data.support_formats).find(item => number(item.quality) === id)?.new_description ?? `${id}`, 100);
    if (videos.length) {
      const ids = [...new Set(videos.map(track => number(track.id)))].sort((a, b) => b - a);
      const selectedId = ids.find(id => id <= quality) ?? ids.at(-1);
      const selected = videos.filter(track => number(track.id) === selectedId).sort((a, b) => number(b.bandwidth) - number(a.bandwidth))[0];
      const video = selected, audio = audios.sort((a, b) => b.bandwidth - a.bandwidth)[0];
      if (!video || (array(dash.audio).length > 0 && !audio)) throw new BiliError('UNSUPPORTED_PLAYBACK', '当前视频没有可用的 AVC/AAC 播放轨道', 422);
      return { cid, quality: video.id, qualities: ids.map(id => ({ id, label: label(id) })), duration: number(dash.duration, number(data.timelength) / 1000), video, ...(audio ? { audio } : {}), subtitles };
    }
    const segments = array(data.durl).map(segment => ({ url: https(segment.url), length: number(segment.length) })).filter(segment => segment.url && segment.length > 0);
    const progressiveMp4 = /mp4/i.test(String(data.format ?? '')) || segments.every(segment => /\.mp4(?:$|\?)/i.test(segment.url));
    if (array(data.durl).length !== 1 || segments.length !== 1 || !progressiveMp4 || !number(data.quality)) throw new BiliError('UNSUPPORTED_PLAYBACK', '当前视频没有浏览器支持的 AVC/AAC 播放流', 422);
    // durl is returned only when upstream actually supplied progressive media, never inferred from DASH.
    return { cid, quality: number(data.quality), qualities: [{ id: number(data.quality), label: label(number(data.quality)) }], duration: number(data.timelength) / 1000, segments, subtitles };
  }

  private dashTrack(raw: RecordValue): DashTrack | undefined {
    const baseUrl = https(raw.baseUrl ?? raw.base_url), segment = object(raw.SegmentBase ?? raw.segment_base);
    const initialization = clean(segment.Initialization ?? segment.initialization, 100), indexRange = clean(segment.indexRange ?? segment.index_range, 100);
    if (!baseUrl || !/^\d+-\d+$/.test(initialization) || !/^\d+-\d+$/.test(indexRange)) return undefined;
    return { id: number(raw.id), baseUrl, backupUrl: (Array.isArray(raw.backupUrl ?? raw.backup_url) ? raw.backupUrl ?? raw.backup_url : []).map(https).filter(Boolean), mimeType: clean(raw.mimeType ?? raw.mime_type, 100), codecs: clean(raw.codecs, 100), bandwidth: number(raw.bandwidth), ...(raw.width ? { width: number(raw.width) } : {}), ...(raw.height ? { height: number(raw.height) } : {}), ...(raw.frameRate || raw.frame_rate ? { frameRate: clean(raw.frameRate ?? raw.frame_rate, 40) } : {}), segmentBase: { initialization, indexRange } };
  }

  async subtitles(bvid: string, cid: number): Promise<Subtitle[]> {
    validBvid(bvid); integer(cid, '分 P 编号');
    const data = await this.transport.request<RecordValue>(`${API}/x/player/wbi/v2`, { wbi: true, query: { bvid, cid } });
    return array(object(data.subtitle).subtitles).map(item => ({ id: clean(item.id_str ?? item.id, 100), lang: clean(item.lan, 40), label: clean(item.lan_doc, 100), url: https(item.subtitle_url) })).filter(item => item.url);
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
    return this.readComments({ oid: integer(aid, '稿件编号'), type: 1 }, page, cursor);
  }

  async dynamicComments(id: string, page = 1, cursor?: string): Promise<Page<Comment>> {
    return this.readComments(await this.dynamicCommentTarget(id), page, cursor);
  }

  private async readComments({ oid, type }: CommentThread, page: number, cursor?: string): Promise<Page<Comment>> {
    const pn = integer(page, '页码');
    if ((pn > 1 && !cursor) || (cursor !== undefined && (cursor.length > 8192 || /[\u0000-\u001f]/.test(cursor)))) throw new BiliError('INVALID_INPUT', '评论翻页标识无效，请重新加载评论', 400);
    const data = await this.transport.request<RecordValue>(`${API}/x/v2/reply/wbi/main`, { wbi: true, query: { type, oid, mode: 2, pagination_str: JSON.stringify({ offset: cursor ?? '' }), plat: 1, web_location: '1315875' } });
    const paging = object(data.cursor), isEnd = [true, 1, '1'].includes(paging.is_end);
    if (!Array.isArray(data.replies) && !(isEnd && number(paging.all_count) === 0)) throw new BiliError('COMMENTS_UNAVAILABLE', clean(object(data.control).show_text, 200) || '评论暂时无法读取，请登录或稍后重试', 502);
    const items = array(data.replies).map(item => mapComment(item)), rawCursor = object(paging.pagination_reply).next_offset;
    const nextCursor = typeof rawCursor === 'string' && rawCursor.length <= 8192 && !/[\u0000-\u001f]/.test(rawCursor) ? rawCursor : '';
    if (!isEnd && (!items.length || !nextCursor)) throw new BiliError('COMMENTS_UNAVAILABLE', '评论分页数据不完整，请稍后重试', 502);
    const hasMore = !isEnd && items.length > 0 && Boolean(nextCursor);
    return { items, hasMore, ...(hasMore ? { nextPage: pn + 1, nextCursor } : {}) };
  }

  async commentReplies(aid: number, root: string, page = 1): Promise<CommentReplyPage> {
    return this.readCommentReplies({ oid: integer(aid, '稿件编号'), type: 1 }, root, page);
  }

  async dynamicCommentReplies(id: string, root: string, page = 1): Promise<CommentReplyPage> {
    return this.readCommentReplies(await this.dynamicCommentTarget(id), root, page);
  }

  private async readCommentReplies({ oid, type }: CommentThread, root: string, page: number): Promise<CommentReplyPage> {
    const pn = integer(page, '页码');
    if (!COMMENT_ID.test(root) || pn > 1000) throw new BiliError('INVALID_INPUT', '回复分页参数无效', 400);
    const data = await this.transport.request<RecordValue>(`${API}/x/v2/reply/reply`, { query: { type, oid, root, pn, ps: 20 } });
    const paging = object(data.page), parent = object(data.root);
    const total = Number(paging.count), size = Number(paging.size);
    const belongsToThread = (row: RecordValue) =>
      ((row.oid === undefined && row.oid_str === undefined) || replyIdentity(row, 'oid') === String(oid)) &&
      (row.type === undefined || row.type === type);
    if (replyIdentity(parent, 'rpid') !== root || !belongsToThread(parent) || Number(paging.num) !== pn || !Number.isSafeInteger(total) || total < 0 || !Number.isSafeInteger(size) || size <= 0 || size > 20 || (!Array.isArray(data.replies) && total !== 0)) throw new BiliError('COMMENTS_UNAVAILABLE', '回复数据不完整或不属于当前评论，请重试', 502);
    const items = array(data.replies).map(item => {
      if (!COMMENT_ID.test(replyIdentity(item, 'rpid')) || replyIdentity(item, 'root') !== root || !belongsToThread(item)) throw new BiliError('COMMENTS_UNAVAILABLE', '回复归属校验失败，请重试', 502);
      return mapComment(item, true);
    });
    const hasMore = pn * size < total;
    if (hasMore && !items.length) throw new BiliError('COMMENTS_UNAVAILABLE', '回复分页数据不完整，请重试', 502);
    return { items, total, hasMore, ...(hasMore ? { nextPage: pn + 1 } : {}) };
  }

  async commentMentionUsers(keyword: string): Promise<User[]> {
    const jar = this.transport.jar;
    const data = await this.transport.request<RecordValue>(`${API}/x/v2/reply/at`, { query: { keyword }, sessionJar: jar });
    this.checkAccount(jar);
    if (data?.groups === null) return [];
    if (!Array.isArray(data?.groups) || data.groups.some((group: unknown) => !Array.isArray(object(group).items))) {
      throw new BiliError('MENTIONS_UNAVAILABLE', '暂时无法读取 @ 用户，请稍后再试。', 502);
    }
    const seen = new Set<number>();
    return array(data.groups).flatMap(group => array(group.items)).map(user)
      .filter(item => Number.isSafeInteger(item.mid) && item.mid > 0 && item.name && !seen.has(item.mid) && Boolean(seen.add(item.mid)))
      .slice(0, 12);
  }

  private async videoCommentTarget(bvid: string): Promise<CommentWriteTarget> {
    const { aid } = await this.video(bvid);
    return { oid: integer(aid, '稿件编号'), type: 1, referer: `https://www.bilibili.com/video/${bvid}` };
  }

  private async dynamicCommentTarget(id: string): Promise<CommentWriteTarget> {
    const item = await this.dynamicItem(id);
    const basic = object(item.basic), oid = replyIdentity(basic, 'comment_id'), type = basic.comment_type;
    const content = object(object(item.modules).module_dynamic);
    const archive = object(object(content.major).archive);
    if (!COMMENT_ID.test(oid) || !Number.isSafeInteger(type) || type <= 0 || (type === 1 && replyIdentity(archive, 'aid') !== oid)) {
      throw new BiliError('COMMENT_UNAVAILABLE', '暂时无法确认该动态的评论区。', 502);
    }
    return { oid, type, referer: `https://t.bilibili.com/${id}` };
  }

  private async commentDetail({ oid, type }: CommentThread, id: string, jar: BiliHttp['jar']): Promise<RecordValue> {
    const data = await this.transport.request<RecordValue>(`${API}/x/v2/reply/detail`, { query: { type, oid, root: id }, sessionJar: jar });
    const item = object(data?.root);
    if (replyIdentity(item, 'rpid') !== id || replyIdentity(item, 'oid') !== String(oid) || item.type !== type) {
      throw new BiliError('COMMENT_UNAVAILABLE', '评论已失效或归属已变化，请刷新评论。', 404);
    }
    return item;
  }

  private async commentWrite<T>(resolve: () => Promise<CommentWriteTarget>, operation: string, accountMid: number,
    write: (target: CommentWriteTarget, jar: BiliHttp['jar'], csrf: string) => Promise<T>): Promise<T> {
    integer(accountMid, '用户编号');
    const jar = this.transport.jar;
    const { csrf, mid } = await this.interactionCredentials();
    this.checkAccount(jar);
    if (mid && mid !== accountMid) throw new BiliError('ACCOUNT_CHANGED', 'B 站账号已切换，请刷新页面。', 409);
    const target = await resolve();
    this.checkAccount(jar);
    const key = `${target.type}:${target.oid}:${operation}`;
    let writes = this.commentWrites.get(jar);
    if (!writes) { writes = new Set(); this.commentWrites.set(jar, writes); }
    if (writes.has(key)) throw new BiliError('COMMENT_BUSY', '这条评论的操作正在处理中。', 409);
    writes.add(key);
    try {
      return await write(target, jar, csrf);
    } finally { writes.delete(key); }
  }

  async postVideoComment(bvid: string, input: CommentSubmission): Promise<Comment> {
    validBvid(bvid);
    return this.postComment(() => this.videoCommentTarget(bvid), input);
  }

  async postDynamicComment(id: string, input: CommentSubmission): Promise<Comment> {
    return this.postComment(() => this.dynamicCommentTarget(id), input);
  }

  private async postComment(resolve: () => Promise<CommentWriteTarget>, input: CommentSubmission): Promise<Comment> {
    const { text, root, parent, names } = commentMessage(input);
    return this.commentWrite(resolve, 'post', input.accountMid, async (target, jar, csrf) => {
      const { oid, type, referer } = target;
      if (parent && root) {
        const replyTo = await this.commentDetail(target, parent, jar);
        if (replyIdentity(replyTo, 'root') !== (parent === root ? '0' : root)) {
          throw new BiliError('INVALID_COMMENT', '这条回复不属于所选评论，请重新选择。', 400);
        }
      }
      await this.prepareInteraction(jar);
      const unconfirmed = () => new BiliError('COMMENT_UNCONFIRMED', 'B 站未返回可确认的评论。请先刷新评论，避免重复发送。', 502);
      let data: RecordValue;
      try {
        data = await this.transport.request<RecordValue>(`${API}/x/v2/reply/add`, {
          method: 'POST', wbi: true, sessionJar: jar,
          form: {
            oid, type, plat: 1, message: text, root, parent, csrf, gaia_source: 'main_web',
            at_name_to_mid: JSON.stringify(Object.fromEntries(names)),
          },
          headers: { origin: 'https://www.bilibili.com', referer },
        });
      } catch (error) {
        if (error instanceof BiliError && (/^5\d\d$/.test(error.code) || ['UPSTREAM_UNAVAILABLE', 'INVALID_RESPONSE'].includes(error.code))) {
          throw unconfirmed();
        }
        throw error;
      }
      this.checkAccount(jar);
      const item = object(data?.reply);
      const comment = mapComment(item, Boolean(root));
      if (!COMMENT_ID.test(comment.id) || replyIdentity(item, 'oid') !== String(oid) ||
          replyIdentity(item, 'root') !== (root ?? '0') || replyIdentity(item, 'parent') !== (parent ?? '0') ||
          item.type !== type || comment.user.mid !== input.accountMid) {
        throw unconfirmed();
      }
      return comment;
    });
  }

  async setVideoCommentLike(bvid: string, id: string, liked: boolean, accountMid: number): Promise<{ liked: boolean; likes: number }> {
    validBvid(bvid);
    return this.setCommentLike(() => this.videoCommentTarget(bvid), id, liked, accountMid);
  }

  async setDynamicCommentLike(dynamicId: string, id: string, liked: boolean, accountMid: number): Promise<{ liked: boolean; likes: number }> {
    return this.setCommentLike(() => this.dynamicCommentTarget(dynamicId), id, liked, accountMid);
  }

  private async setCommentLike(resolve: () => Promise<CommentWriteTarget>, id: string, liked: boolean, accountMid: number): Promise<{ liked: boolean; likes: number }> {
    if (!COMMENT_ID.test(id) || typeof liked !== 'boolean') throw new BiliError('INVALID_COMMENT', '评论或点赞目标无效。', 400);
    return this.commentWrite(resolve, `like:${id}`, accountMid, async (target, jar, csrf) => {
      const { oid, type, referer } = target;
      const state = async () => {
        this.checkAccount(jar);
        const item = await this.commentDetail(target, id, jar);
        this.checkAccount(jar);
        if (![0, 1, 2].includes(item.action) || !Number.isSafeInteger(item.like) || item.like < 0) {
          throw new BiliError('COMMENT_UNAVAILABLE', '暂时无法读取评论点赞状态。', 502);
        }
        return { liked: item.action === 1, likes: Number(item.like) };
      };
      const before = await state();
      if (before.liked === liked) return before;
      await this.prepareInteraction(jar);
      await this.transport.request(`${API}/x/v2/reply/action`, {
        method: 'POST', sessionJar: jar, form: { oid, type, rpid: id, action: liked ? 1 : 0, csrf },
        headers: { origin: 'https://www.bilibili.com', referer },
      });
      let confirmed: DynamicLikeState | undefined;
      for (const delay of LIKE_CONFIRM_DELAYS) {
        if (delay) await new Promise(resolve => setTimeout(resolve, delay));
        try {
          const current = await state();
          if (current.liked !== liked) continue;
          if (current.likes !== before.likes) return current;
          confirmed = current;
        }
        catch (error) { this.checkAccount(jar); if (error instanceof BiliError && error.status === 401) throw error; }
      }
      if (confirmed) return confirmed;
      throw new BiliError('COMMENT_LIKE_UNCONFIRMED', '点赞结果暂未确认，请刷新评论后再操作。', 502);
    });
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
