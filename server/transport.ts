import { createHash } from 'node:crypto';
import { CookieJar, type Cookie } from 'tough-cookie';

export class BiliError extends Error {
  readonly code: string;
  constructor(code: string | number, message: string, readonly status = 502) { super(message); this.name = 'BiliError'; this.code = String(code); }
}
type Values = Record<string, string | number | boolean | undefined>;
export interface BiliRequestOptions { method?: 'GET' | 'POST'; query?: Values; form?: Values; wbi?: boolean; headers?: Record<string, string>; onResponseCookies?: (names: readonly string[]) => void }
interface Envelope<T> { code: number; message?: string; msg?: string; data: T }
const MIXIN = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52];
const USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15';
function trustedUrl(value: string | URL): URL {
  const url = new URL(value, 'https://api.bilibili.com');
  const allowed = ['bilibili.com', 'hdslb.com', 'bilivideo.com', 'bilivideo.cn'].some(host => url.hostname === host || url.hostname.endsWith(`.${host}`)) || ['b23.tv', 'www.b23.tv'].includes(url.hostname);
  if (url.protocol !== 'https:' || url.port || url.username || url.password || !allowed) throw new BiliError('INVALID_UPSTREAM', '不支持的上游地址', 400);
  return url;
}
export class BiliHttp {
  public jar: CookieJar;
  public onCookiesChanged?: () => void | Promise<void>;
  private readonly fetcher: typeof fetch;
  private readonly now: () => number;
  private readonly responseCookies = new WeakMap<Response, { jar: CookieJar; names: string[] }>();
  private wbiKey?: { value: string; expires: number };
  private wbiLoading?: Promise<string>;
  private readonly deviceRequests = new WeakMap<CookieJar, Promise<void>>();
  constructor(options: { fetch?: typeof fetch; jar?: CookieJar; now?: () => number } = {}) { this.fetcher = options.fetch ?? fetch; this.jar = options.jar ?? new CookieJar(); this.now = options.now ?? Date.now; }
  async fetchWithCookies(value: string | URL, init: RequestInit = {}): Promise<Response> {
    let url = trustedUrl(value), method = init.method ?? 'GET', body = init.body;
    const requestedHeaders = new Headers(init.headers);
    for (let hop = 0; hop <= 5; hop++) {
      const headers = new Headers(requestedHeaders);
      headers.delete('cookie');
      if (!headers.has('user-agent')) headers.set('user-agent', USER_AGENT);
      if (!headers.has('referer')) headers.set('referer', 'https://www.bilibili.com/');
      const jar = this.jar;
      const cookies = await jar.getCookieString(url.href);
      if (cookies) headers.set('cookie', cookies);
      let response: Response;
      try { response = await this.fetcher(url, { ...init, method, body, headers, redirect: 'manual' }); }
      catch { throw new BiliError('UPSTREAM_UNAVAILABLE', '暂时无法连接哔哩哔哩，请稍后重试'); }
      const setCookies = response.headers.getSetCookie();
      // Logout replaces the jar, so responses already in flight cannot restore it.
      if (this.jar === jar) {
        const accepted: Cookie[] = [];
        for (const cookie of setCookies) {
          const saved = await jar.setCookie(cookie, url.href, { ignoreError: true });
          if (saved) accepted.push(saved);
        }
        const usable = await jar.getCookies('https://www.bilibili.com/');
        // Only this response's accepted, applicable cookies prove a fresh login.
        const names = accepted.filter(saved => usable.some(cookie => cookie.key === saved.key && cookie.domain === saved.domain && cookie.path === saved.path && cookie.value === saved.value)).map(cookie => cookie.key);
        this.responseCookies.set(response, { jar, names: [...new Set(names)] });
        if (setCookies.length) await this.onCookiesChanged?.();
      }
      const location = response.headers.get('location');
      if (init.redirect === 'manual' || ![301,302,303,307,308].includes(response.status) || !location) return response;
      if (init.redirect === 'error') { await response.body?.cancel(); throw new BiliError('UPSTREAM_REDIRECT', '上游返回了意外跳转'); }
      await response.body?.cancel();
      if (response.status === 303 || ([301,302].includes(response.status) && method.toUpperCase() === 'POST')) { method = 'GET'; body = undefined; requestedHeaders.delete('content-type'); }
      url = trustedUrl(new URL(location, url));
    }
    throw new BiliError('UPSTREAM_REDIRECT', '上游跳转次数过多');
  }
  async request<T>(value: string, options: BiliRequestOptions = {}): Promise<T> {
    const url = trustedUrl(value);
    for (const [key, item] of Object.entries(options.query ?? {})) if (item !== undefined) url.searchParams.set(key, String(item));
    if (options.wbi) await this.sign(url);
    const headers = new Headers(options.headers);
    let body: URLSearchParams | undefined;
    if (options.form) {
      body = new URLSearchParams();
      for (const [key, item] of Object.entries(options.form)) if (item !== undefined) body.set(key, String(item));
      headers.set('content-type', 'application/x-www-form-urlencoded');
    }
    const response = await this.fetchWithCookies(url, { method: options.method ?? (body ? 'POST' : 'GET'), body, headers, signal: AbortSignal.timeout(20_000) });
    const issued = this.responseCookies.get(response);
    options.onResponseCookies?.(issued?.jar === this.jar ? issued.names : []);
    if (!response.ok) throw new BiliError(response.status, response.status === 412 || response.status === 429 ? '哔哩哔哩暂时限制了请求，请稍后重试' : '哔哩哔哩服务暂时不可用', response.status === 429 ? 429 : 502);
    let result: Envelope<T>;
    try { result = await response.json() as Envelope<T>; } catch { throw new BiliError('INVALID_RESPONSE', '哔哩哔哩返回了无法识别的数据'); }
    if (typeof result.code !== 'number') throw new BiliError('INVALID_RESPONSE', '哔哩哔哩返回了无法识别的数据');
    if (result.code !== 0) throw new BiliError(result.code, result.message || result.msg || '哔哩哔哩请求失败', result.code === -101 ? 401 : 502);
    return result.data;
  }
  async ensureDeviceCookies(): Promise<void> {
    const jar = this.jar;
    if ((await jar.getCookies('https://api.bilibili.com/')).some(cookie => cookie.key === 'buvid3' && cookie.value)) return;
    const pending = this.deviceRequests.get(jar);
    if (pending) return pending;
    const task = (async () => {
      const data = await this.request<{ b_3: string; b_4?: string }>('https://api.bilibili.com/x/frontend/finger/spi');
      if (this.jar !== jar) throw new BiliError('LOGIN_REQUIRED', '账号状态已变化，请重试', 401);
      if (typeof data?.b_3 !== 'string' || !/^[A-Za-z0-9_-]{10,256}$/.test(data.b_3)) throw new BiliError('INVALID_RESPONSE', '无法获取哔哩哔哩网页访客标识，请稍后重试');
      for (const [name, value] of [['buvid3', data.b_3], ['buvid4', data.b_4]] as const) {
        if (typeof value === 'string' && /^[A-Za-z0-9_=%+./-]{10,512}$/.test(value)) await jar.setCookie(`${name}=${value}; Domain=.bilibili.com; Path=/; Secure; Max-Age=31536000`, 'https://www.bilibili.com/');
      }
      if (this.jar !== jar) throw new BiliError('LOGIN_REQUIRED', '账号状态已变化，请重试', 401);
      await this.onCookiesChanged?.();
    })();
    this.deviceRequests.set(jar, task);
    try { await task; } finally { this.deviceRequests.delete(jar); }
  }
  private async sign(url: URL): Promise<void> {
    const key = await this.getWbiKey();
    url.searchParams.set('wts', String(Math.floor(this.now() / 1000)));
    const encoded = [...url.searchParams.entries()].filter(([name]) => name !== 'w_rid').sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([name, value]) => `${encodeURIComponent(name)}=${encodeURIComponent(value.replace(/[!'()*]/g, ''))}`).join('&');
    // WBI signs the exact sorted query; URLSearchParams would turn spaces into '+'.
    url.search = `${encoded}&w_rid=${createHash('md5').update(encoded + key).digest('hex')}`;
  }
  private async getWbiKey(): Promise<string> {
    if (this.wbiKey && this.wbiKey.expires > this.now()) return this.wbiKey.value;
    if (!this.wbiLoading) this.wbiLoading = (async () => {
      // Anonymous nav can report code -101 while still supplying public WBI keys.
      const response = await this.fetchWithCookies('https://api.bilibili.com/x/web-interface/nav', { signal: AbortSignal.timeout(20_000) });
      if (!response.ok) throw new BiliError('UPSTREAM_UNAVAILABLE', '无法获取搜索签名信息');
      const envelope = await response.json() as Envelope<{ wbi_img?: { img_url: string; sub_url: string } }>;
      const nav = envelope.data;
      if (!nav?.wbi_img?.img_url || !nav.wbi_img.sub_url) throw new BiliError('INVALID_RESPONSE', '无法获取搜索签名信息');
      const stem = (value: string) => new URL(value).pathname.split('/').pop()!.split('.')[0];
      const raw = stem(nav.wbi_img.img_url) + stem(nav.wbi_img.sub_url);
      if (raw.length !== 64) throw new BiliError('INVALID_RESPONSE', '无法获取搜索签名信息');
      const value = MIXIN.map(index => raw[index]).join('').slice(0, 32);
      this.wbiKey = { value, expires: this.now() + 10 * 60_000 };
      return value;
    })().finally(() => { this.wbiLoading = undefined; });
    return this.wbiLoading;
  }
}
