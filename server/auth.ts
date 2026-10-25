import { constants, publicEncrypt, randomUUID } from 'node:crypto';
import { CookieJar } from 'tough-cookie';
import type { AuthState, CaptchaChallenge, Country, LoginResult, QrChallenge, QrState, SmsSend, SmsTicket, User } from '../shared/types.js';
import { BiliError, BiliHttp } from './transport.js';
import { SecretStore } from './store.js';

const PASSPORT = 'https://passport.bilibili.com';
const QR_TTL = 180_000, CAPTCHA_TTL = 300_000, SMS_TTL = 300_000;
const REFRESH_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDLgd2OAkcGVtoE3ThUREbio0Eg
Uc/prcajMKXvkCKFCWhJYJcLkcM2DKKcSeFpD/j6Boy538YXnR6VhcuUJOhH2x71
nzPjfdTcqMz7djHum0qSZA0AyCBDABUqCrfNgCiJ00Ra7GmRj+YCK1NJEuewlb40
JNrRuoEUXpabUzGB8QIDAQAB
-----END PUBLIC KEY-----`;
interface StoredCredentials { jar: NonNullable<ReturnType<CookieJar['serializeSync']>>; refreshToken?: string; user?: User }
interface Nav { isLogin: boolean; mid: number; uname: string; face: string }
interface LoginData { code?: number; status?: number; url?: string; refresh_token?: string; message?: string }
interface CompletedLogin { data: LoginData; cookieNames: Set<string> }
interface PendingQr { key: string; expires: number; completed?: CompletedLogin }
interface PendingCaptcha { token: string; expires: number; sentAt?: number }
interface PendingSms { tel: string; cid: number; key: string; expires: number; completed?: CompletedLogin }

function passportUrl(value: string | undefined): string {
  try { const url = new URL(value ?? ''); if (url.protocol === 'https:' && ['passport.bilibili.com', 'account.bilibili.com'].includes(url.hostname) && !url.port && !url.username && !url.password) return url.href; } catch { /* Invalid URLs are never sent to the browser. */ }
  throw new BiliError('INVALID_RESPONSE', '哔哩哔哩返回了无法识别的登录地址');
}
function cookieExchangeUrl(value: string): URL {
  const invalid = () => new BiliError('INVALID_RESPONSE', '哔哩哔哩返回了无法识别的登录地址');
  let url: URL;
  try { url = new URL(value); } catch { throw invalid(); }
  if (url.protocol !== 'https:' || url.port || url.username || url.password) throw invalid();
  const bili = ['passport.bilibili.com', 'account.bilibili.com'].includes(url.hostname);
  const game = url.hostname === 'passport.biligame.com' && url.pathname === '/crossDomain';
  if (!bili && !game) throw invalid();
  // This URL is parsed only; it is never requested or returned to the browser.
  return url;
}
function verificationUrl(value: string | undefined): string {
  const url = new URL(passportUrl(value)), original = new URLSearchParams(url.search);
  url.search = ''; url.hash = '';
  // Cookie exchange URLs stay server-side. Only these safety-flow fields leave it.
  const allowed = new Set(['tmp_token', 'request_id', 'requestid', 'bind_tel', 'source', 'from', 'type']);
  for (const [name, item] of original) if (allowed.has(name.toLowerCase()) && item.length <= 2048 && !/sessdata|bili_jct|refresh_token|dedeuserid/i.test(item)) url.searchParams.append(name, item);
  if (/sessdata|bili_jct|refresh_token|dedeuserid/i.test(url.href)) throw new BiliError('INVALID_RESPONSE', '登录验证地址包含异常数据');
  return url.href;
}
export class AuthService {
  private authenticated = false;
  private user?: User;
  private message?: string;
  private refreshToken?: string;
  private readonly now: () => number;
  private readonly intervalMs: number;
  private timer?: ReturnType<typeof setInterval>;
  private refreshInFlight?: Promise<void>;
  private queue: Promise<unknown> = Promise.resolve();
  private initialized = false;
  private qr = new Map<string, PendingQr>();
  private challenges = new Map<string, PendingCaptcha>();
  private sms = new Map<string, PendingSms>();
  private countryCache?: { items: Country[]; expires: number };
  constructor(private readonly http: BiliHttp, private readonly store: SecretStore, options: { now?: () => number; refreshIntervalMs?: number } = {}) {
    this.now = options.now ?? Date.now;
    this.intervalMs = options.refreshIntervalMs ?? 60 * 60_000;
  }
  async init(): Promise<void> {
    if (this.initialized) return;
    this.initialized = true;
    const saved = this.store.get<StoredCredentials>('credentials');
    if (saved) {
      this.http.jar = CookieJar.deserializeSync(saved.jar);
      this.refreshToken = saved.refreshToken;
      this.user = saved.user;
      this.authenticated = true;
      try { await this.refresh(); } catch { this.message = '暂时无法验证登录状态，稍后会自动重试'; }
    }
    this.http.onCookiesChanged = () => { if (this.authenticated) this.persist(); };
    if (this.intervalMs > 0) {
      this.timer = setInterval(() => { void this.refresh().catch(() => { this.message = '登录状态检查暂时失败，稍后会自动重试'; }); }, this.intervalMs);
      this.timer.unref();
    }
  }
  async close(): Promise<void> { if (this.timer) clearInterval(this.timer); await this.queue.catch(() => {}); this.http.onCookiesChanged = undefined; }
  async state(): Promise<AuthState> { return { authenticated: this.authenticated, ...(this.user && this.authenticated ? { user: this.user } : {}), needsLogin: !this.authenticated && Boolean(this.message), ...(this.message ? { message: this.message } : {}) }; }
  async qrCreate(): Promise<QrChallenge> {
    this.prune();
    const data = await this.http.request<{ url: string; qrcode_key: string }>(`${PASSPORT}/x/passport-login/web/qrcode/generate`, { query: { source: 'main-fe-header' } });
    const url = passportUrl(data.url);
    if (!data.qrcode_key) throw new BiliError('INVALID_RESPONSE', '无法创建登录二维码');
    const id = randomUUID(), expiresAt = this.now() + QR_TTL;
    this.qr.set(id, { key: data.qrcode_key, expires: expiresAt });
    return { id, url, expiresAt };
  }
  async qrPoll(id: string): Promise<QrState> {
    return this.exclusive(async () => {
      const pending = this.qr.get(id);
      if (!pending || pending.expires <= this.now()) { this.qr.delete(id); return { state: 'expired' }; }
      const cookieNames = pending.completed?.cookieNames ?? new Set<string>();
      const data = pending.completed?.data ?? await this.http.request<LoginData>(`${PASSPORT}/x/passport-login/web/qrcode/poll`, { query: { qrcode_key: pending.key, source: 'main-fe-header' }, onResponseCookies: names => names.forEach(name => cookieNames.add(name)) });
      if (data.code === 86101) return { state: 'waiting' };
      if (data.code === 86090) return { state: 'scanned' };
      if (data.code === 86038) { this.qr.delete(id); return { state: 'expired' }; }
      if (data.code !== 0) throw new BiliError(data.code ?? 'INVALID_RESPONSE', data.message || '二维码登录未完成');
      pending.completed = { data, cookieNames };
      const result = await this.finishLogin(data, cookieNames);
      this.qr.delete(id);
      return result;
    });
  }
  async countries(): Promise<Country[]> {
    if (this.countryCache && this.countryCache.expires > this.now()) return this.countryCache.items;
    const data = await this.http.request<{ common?: unknown[]; others?: unknown[]; list?: unknown[] }>(`${PASSPORT}/web/generic/country/list`);
    const rows = [...(data.common ?? []), ...(data.others ?? []), ...(data.list ?? [])];
    const unique = new Map<number, Country>();
    for (const row of rows) {
      const item = row as Record<string, unknown>, id = Number(item.id), code = String(item.country_id ?? ''), name = String(item.cname ?? item.name ?? '');
      if (Number.isInteger(id) && id > 0 && /^\d{1,4}$/.test(code) && name) unique.set(id, { id, name, code });
    }
    if (!unique.size) throw new BiliError('INVALID_RESPONSE', '暂时无法读取国家和地区列表');
    const items = [...unique.values()];
    this.countryCache = { items, expires: this.now() + 24 * 60 * 60_000 };
    return items;
  }
  async captcha(): Promise<CaptchaChallenge> {
    this.prune();
    const data = await this.http.request<{ token: string; geetest: { gt: string; challenge: string } }>(`${PASSPORT}/x/passport-login/captcha`, { query: { source: 'main_web' } });
    if (!data.token || !data.geetest?.gt || !data.geetest.challenge) throw new BiliError('INVALID_RESPONSE', '暂时无法加载验证组件');
    const id = randomUUID();
    this.challenges.set(id, { token: data.token, expires: this.now() + CAPTCHA_TTL });
    return { id, gt: data.geetest.gt, challenge: data.geetest.challenge };
  }
  async sendSms(input: SmsSend): Promise<SmsTicket> {
    return this.exclusive(async () => {
      const pending = this.challenges.get(input.challengeId);
      if (!pending || pending.expires <= this.now()) throw new BiliError('CHALLENGE_EXPIRED', '验证已过期，请重新验证', 410);
      const tel = input.tel.replace(/[\s()-]/g, '');
      if (!/^\d{5,15}$/.test(tel) || !Number.isInteger(input.cid) || !input.validate || !input.seccode || !input.challenge || input.challenge.length > 200 || input.validate.length > 2048 || input.seccode.length > 2048) throw new BiliError('INVALID_INPUT', '请检查手机号并完成验证', 400);
      const country = (await this.countries()).find(item => item.id === input.cid);
      if (!country) throw new BiliError('INVALID_INPUT', '请选择有效的国家或地区', 400);
      if (pending.sentAt !== undefined && this.now() - pending.sentAt < 60_000) throw new BiliError('SMS_COOLDOWN', '请稍后再发送验证码', 429);
      pending.sentAt = this.now();
      // Geetest can refresh the challenge; Bilibili validates its binding to our token.
      const data = await this.http.request<{ captcha_key: string }>(`${PASSPORT}/x/passport-login/web/sms/send`, { method: 'POST', form: { source: 'main_web', tel, cid: country.id, token: pending.token, challenge: input.challenge, validate: input.validate, seccode: input.seccode } });
      if (!data.captcha_key) throw new BiliError('INVALID_RESPONSE', '未取得短信验证凭据');
      const id = randomUUID(), expiresAt = this.now() + SMS_TTL;
      this.sms.set(id, { tel, cid: country.id, key: data.captcha_key, expires: expiresAt });
      return { id, expiresAt };
    });
  }
  async loginSms(input: { id: string; code: string }): Promise<LoginResult> {
    return this.exclusive(async () => {
      const pending = this.sms.get(input.id);
      if (!pending || pending.expires <= this.now()) throw new BiliError('CHALLENGE_EXPIRED', '短信验证码已过期，请重新发送', 410);
      if (!/^\d{4,8}$/.test(input.code)) throw new BiliError('INVALID_INPUT', '请输入正确的短信验证码', 400);
      const cookieNames = pending.completed?.cookieNames ?? new Set<string>();
      const data = pending.completed?.data ?? await this.http.request<LoginData>(`${PASSPORT}/x/passport-login/web/login/sms`, { method: 'POST', form: { tel: pending.tel, cid: pending.cid, code: input.code, source: 'main_web', captcha_key: pending.key, keep: true }, onResponseCookies: names => names.forEach(name => cookieNames.add(name)) });
      pending.completed = { data, cookieNames };
      const result = await this.finishLogin(data, cookieNames);
      this.sms.delete(input.id);
      return result;
    });
  }
  async logout(): Promise<void> {
    await this.exclusive(async () => {
      // Local sign-out does not unexpectedly invalidate other Bilibili browser sessions.
      this.authenticated = false; this.user = undefined; this.refreshToken = undefined; this.message = undefined;
      this.qr.clear(); this.challenges.clear(); this.sms.clear();
      this.http.jar = new CookieJar(); this.store.delete('credentials');
    });
  }
  /** Public for manual retry and account-free injected-fetch verification. */
  async refresh(): Promise<void> {
    if (this.refreshInFlight) return this.refreshInFlight;
    this.refreshInFlight = this.exclusive(async () => {
      if (!this.authenticated) return;
      try {
        const cookies = await this.http.jar.getCookies('https://www.bilibili.com/');
        const csrf = cookies.find(cookie => cookie.key === 'bili_jct')?.value;
        if (this.refreshToken && csrf) {
          const info = await this.http.request<{ refresh: boolean }>(`${PASSPORT}/x/passport-login/web/cookie/info`, { query: { csrf } });
          if (info.refresh) await this.refreshCookies(csrf);
        }
        const nav = await this.http.request<Nav>('/x/web-interface/nav');
        if (!nav.isLogin) { await this.invalidate(); return; }
        this.user = { mid: nav.mid, name: nav.uname, avatar: nav.face };
        this.message = undefined; this.persist();
      } catch (error) {
        if (error instanceof BiliError && ['-101', '-111', '61000'].includes(error.code)) { await this.invalidate(); return; }
        throw error;
      }
    }).finally(() => { this.refreshInFlight = undefined; });
    return this.refreshInFlight;
  }
  private async finishLogin(data: LoginData, responseCookieNames: Set<string>): Promise<LoginResult> {
    if (data.status === 5 || (data.url && /\/risk\/|\/safecenter\//.test(data.url))) return { state: 'verification_required', verificationUrl: verificationUrl(data.url) };
    const existing = await this.http.jar.getCookies('https://www.bilibili.com/');
    let newSession = responseCookieNames.has('SESSDATA') && existing.some(cookie => cookie.key === 'SESSDATA' && Boolean(cookie.value));
    // The official success response already sets the session. Its optional SSO
    // ticket URL is irrelevant here: never parse, request or expose it in that case.
    if (!newSession && data.url) {
      const url = cookieExchangeUrl(data.url);
      for (const name of ['SESSDATA', 'bili_jct', 'DedeUserID']) {
        // A genuine response cookie wins over URL fallback data. Preserve escaping.
        if (responseCookieNames.has(name) && existing.some(cookie => cookie.key === name)) continue;
        const raw = url.search.slice(1).split('&').find(item => item.split('=')[0].toLowerCase() === name.toLowerCase());
        const value = raw?.slice(raw.indexOf('=') + 1);
        if (name === 'SESSDATA' && value) newSession = true;
        if (value) await this.http.jar.setCookie(`${name}=${value}; Domain=.bilibili.com; Path=/; Secure; HttpOnly`, PASSPORT);
      }
    }
    const savedCookies = await this.http.jar.getCookies('https://www.bilibili.com/');
    if (!newSession || !savedCookies.some(cookie => cookie.key === 'SESSDATA')) throw new BiliError('INVALID_RESPONSE', '登录未返回有效凭据，请重新登录');
    const nav = await this.http.request<Nav>('/x/web-interface/nav');
    if (!nav.isLogin || !nav.mid) throw new BiliError('LOGIN_INCOMPLETE', '登录尚未完成，请重新登录', 401);
    this.authenticated = true; this.refreshToken = data.refresh_token; this.user = { mid: nav.mid, name: nav.uname, avatar: nav.face }; this.message = undefined;
    this.persist();
    return { state: 'authenticated' };
  }
  private async refreshCookies(csrf: string): Promise<void> {
    const correspond = publicEncrypt({ key: REFRESH_PUBLIC_KEY, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, Buffer.from(`refresh_${this.now()}`)).toString('hex');
    const response = await this.http.fetchWithCookies(`https://www.bilibili.com/correspond/1/${correspond}`, { signal: AbortSignal.timeout(20_000) });
    if (!response.ok) throw new BiliError('REFRESH_FAILED', '登录刷新失败，请重新登录');
    const token = (await response.text()).match(/<div\s+id=["']1-name["'][^>]*>([^<]+)<\/div>/)?.[1];
    if (!token) throw new BiliError('REFRESH_FAILED', '无法取得登录刷新凭据');
    const previousToken = this.refreshToken;
    const data = await this.http.request<{ refresh_token: string }>(`${PASSPORT}/x/passport-login/web/cookie/refresh`, { method: 'POST', form: { csrf, refresh_csrf: token, refresh_token: previousToken, source: 'main_web' } });
    if (!data.refresh_token) throw new BiliError('REFRESH_FAILED', '登录刷新未返回新凭据');
    this.refreshToken = data.refresh_token; this.persist();
    const newCsrf = (await this.http.jar.getCookies('https://www.bilibili.com/')).find(cookie => cookie.key === 'bili_jct')?.value;
    await this.http.request(`${PASSPORT}/x/passport-login/web/confirm/refresh`, { method: 'POST', form: { csrf: newCsrf, refresh_token: previousToken } });
  }
  private persist(): void {
    const jar = this.http.jar.serializeSync();
    if (!jar) throw new Error('无法保存登录状态');
    this.store.set('credentials', { jar, refreshToken: this.refreshToken, user: this.user } satisfies StoredCredentials);
  }
  private async invalidate(): Promise<void> { this.authenticated = false; this.user = undefined; this.refreshToken = undefined; this.message = '登录已失效，请重新登录'; this.http.jar = new CookieJar(); this.store.delete('credentials'); }
  private exclusive<T>(operation: () => Promise<T>): Promise<T> { const result = this.queue.then(operation); this.queue = result.catch(() => {}); return result; }
  private prune(): void {
    for (const map of [this.qr, this.challenges, this.sms]) {
      for (const [id, item] of map) if (item.expires <= this.now()) map.delete(id);
      while (map.size >= 20) map.delete(map.keys().next().value!);
    }
  }
}
