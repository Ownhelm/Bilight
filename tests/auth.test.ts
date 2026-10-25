import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import test from 'node:test';
import { AuthService } from '../server/auth.js';
import { SecretStore } from '../server/store.js';
import { BiliError, BiliHttp } from '../server/transport.js';

const json = (data: unknown, code = 0, headers?: HeadersInit) => new Response(JSON.stringify({ code, data }), { headers: { 'content-type': 'application/json', ...headers } });
const nav = { isLogin: true, mid: 42, uname: '测试账号', face: 'https://i0.hdslb.com/avatar.png' };
function fixture(handler: (url: URL, init: RequestInit) => Response | Promise<Response>, options: { now?: () => number } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'bilight-auth-')), path = join(directory, 'test.sqlite'), key = randomBytes(32);
  const http = new BiliHttp({ fetch: ((url: string | URL | Request, init?: RequestInit) => handler(new URL(String(url)), init ?? {})) as typeof fetch, now: options.now });
  const store = new SecretStore(path, key), auth = new AuthService(http, store, { now: options.now, refreshIntervalMs: 0 });
  return { auth, http, store, path, key, async clean() { await auth.close(); store.close(); rmSync(directory, { recursive: true, force: true }); } };
}
test('first visit and deliberate logout do not claim an expired login', async () => {
  const f = fixture(() => { throw new Error('First visit does not call upstream'); });
  try { await f.auth.init(); assert.equal((await f.auth.state()).needsLogin, false); await f.auth.logout(); assert.equal((await f.auth.state()).needsLogin, false); }
  finally { await f.clean(); }
});
test('QR state stays anonymous until Bilibili confirms valid credentials; secrets survive encrypted restart', async () => {
  let poll = 0;
  const f = fixture(url => {
    if (url.pathname.endsWith('/generate')) return json({ url: 'https://account.bilibili.com/h5-app/passport/login/scan?key=private-qr', qrcode_key: 'private-qr' });
    if (url.pathname.endsWith('/poll')) { assert.equal(url.searchParams.get('qrcode_key'), 'private-qr'); return json(poll++ === 0 ? { code: 86090 } : { code: 0, url: 'https://passport.bilibili.com/crossDomain?SESSDATA=private-session&bili_jct=private-csrf&DedeUserID=42', refresh_token: 'private-refresh' }); }
    if (url.pathname.endsWith('/cookie/info')) return json({ refresh: false });
    if (url.pathname.endsWith('/nav')) return json(nav);
    throw new Error('Unexpected upstream');
  });
  try {
    await f.auth.init(); const qr = await f.auth.qrCreate();
    assert.notEqual(qr.id, 'private-qr'); assert.equal((await f.auth.qrPoll(qr.id)).state, 'scanned'); assert.equal((await f.auth.state()).authenticated, false);
    assert.equal((await f.auth.qrPoll(qr.id)).state, 'authenticated'); assert.equal((await f.auth.state()).user?.mid, 42);
    assert(!readFileSync(f.path).includes(Buffer.from('private-session'))); assert(!readFileSync(f.path).includes(Buffer.from('private-refresh')));
    await f.auth.close();
    const restarted = new AuthService(f.http, f.store, { refreshIntervalMs: 0 });
    await restarted.init(); assert.equal((await restarted.state()).authenticated, true); await restarted.logout();
    assert.equal(f.store.get('credentials'), undefined); assert.equal(await f.http.jar.getCookieString('https://api.bilibili.com/'), ''); await restarted.close();
  } finally { await f.clean(); }
});
test('QR expiry and unknown result never claim authentication', async () => {
  let now = 1_000;
  const f = fixture(url => url.pathname.endsWith('/generate') ? json({ url: 'https://passport.bilibili.com/scan', qrcode_key: 'key' }) : json({ code: 1234, message: 'unexpected' }), { now: () => now });
  try {
    await f.auth.init(); const qr = await f.auth.qrCreate();
    await assert.rejects(f.auth.qrPoll(qr.id), (error: unknown) => error instanceof BiliError && error.code === '1234');
    now += 181_000; assert.deepEqual(await f.auth.qrPoll(qr.id), { state: 'expired' }); assert.equal((await f.auth.state()).authenticated, false);
  } finally { await f.clean(); }
});
test('SMS carries Bilibili region ID and challenge proof; verification-required is not login', async () => {
  let sends = 0;
  const f = fixture((url, init) => {
    if (url.pathname.endsWith('/country/list')) return json({ common: [{ id: 1, cname: '中国', country_id: 86 }], others: [{ id: 44_001, cname: '英国', country_id: 44 }] });
    if (url.pathname.endsWith('/captcha')) return json({ token: 'captcha-token', geetest: { gt: 'gt', challenge: 'challenge' } });
    if (url.pathname.endsWith('/sms/send')) {
      const body = new URLSearchParams(String(init.body)); assert.equal(body.get('cid'), '44001'); assert.equal(body.get('tel'), '7700900123'); assert.equal(body.get('token'), 'captcha-token'); assert.equal(body.get('validate'), 'human-proof'); assert.equal(body.get('challenge'), 'provider-final-challenge'); sends++; return json({ captcha_key: 'sms-secret' });
    }
    if (url.pathname.endsWith('/login/sms')) { const body = new URLSearchParams(String(init.body)); assert.equal(body.get('captcha_key'), 'sms-secret'); return json({ status: 5, url: 'https://passport.bilibili.com/pc/passport/risk/secTip?tmp_token=official&SESSDATA=must-not-leak&bili_jct=csrf&gourl=https%3A%2F%2Fevil.example%2F%3FSESSDATA%3Dleak' }); }
    throw new Error('Unexpected upstream');
  });
  try {
    await f.auth.init(); const captcha = await f.auth.captcha(), input = { challengeId: captcha.id, tel: '7700900123', cid: 44_001, challenge: 'provider-final-challenge', validate: 'human-proof', seccode: 'proof|jordan' };
    await assert.rejects(f.auth.sendSms({ ...input, challenge: '' }), (error: unknown) => error instanceof BiliError && error.code === 'INVALID_INPUT');
    const ticket = await f.auth.sendSms(input); assert.notEqual(ticket.id, 'sms-secret');
    await assert.rejects(f.auth.sendSms(input), (error: unknown) => error instanceof BiliError && error.code === 'SMS_COOLDOWN');
    assert.equal(sends, 1); const result = await f.auth.loginSms({ id: ticket.id, code: '123456' }); assert.equal(result.state, 'verification_required'); assert.equal(result.verificationUrl, 'https://passport.bilibili.com/pc/passport/risk/secTip?tmp_token=official');
    assert.equal((await f.auth.state()).authenticated, false); assert.equal(f.store.get('credentials'), undefined);
  } finally { await f.clean(); }
});
test('SMS expired challenges do not send messages and unsafe verification links are rejected', async () => {
  let now = 0, calls = 0;
  const f = fixture(url => { calls++; return json(url.pathname.endsWith('/generate') ? { url: 'https://passport.bilibili.com/scan', qrcode_key: 'key' } : { code: 0, status: 5, url: 'https://evil.example/risk/' }); }, { now: () => now });
  try {
    await f.auth.init(); await assert.rejects(f.auth.sendSms({ challengeId: 'missing', tel: '12345678', cid: 1, challenge: 'a', validate: 'b', seccode: 'c' }), (error: unknown) => error instanceof BiliError && error.status === 410); assert.equal(calls, 0);
    const qr = await f.auth.qrCreate(); await assert.rejects(f.auth.qrPoll(qr.id), (error: unknown) => error instanceof BiliError && error.code === 'INVALID_RESPONSE');
    assert.equal((await f.auth.state()).authenticated, false); now++;
  } finally { await f.clean(); }
});
test('parallel refresh rotates once, persists new cookies and token, and confirms old token', async () => {
  let infoCalls = 0, refreshCalls = 0, lastForm: URLSearchParams | undefined, expectedPrevious = 'old-refresh';
  const f = fixture((url, init) => {
    if (url.pathname.endsWith('/cookie/info')) { infoCalls++; return json({ refresh: true }); }
    if (url.pathname.includes('/correspond/1/')) return new Response('<div id="1-name">refresh-csrf</div>');
    if (url.pathname.endsWith('/cookie/refresh')) {
      refreshCalls++; lastForm = new URLSearchParams(String(init.body));
      const headers = new Headers(); headers.append('set-cookie', 'SESSDATA=new-session; Domain=.bilibili.com; Path=/; Secure; HttpOnly'); headers.append('set-cookie', 'bili_jct=new-csrf; Domain=.bilibili.com; Path=/; Secure; HttpOnly');
      return new Response(JSON.stringify({ code: 0, data: { refresh_token: 'new-refresh' } }), { headers });
    }
    if (url.pathname.endsWith('/confirm/refresh')) { const body = new URLSearchParams(String(init.body)); assert.equal(body.get('refresh_token'), expectedPrevious); expectedPrevious = 'new-refresh'; assert.equal(body.get('csrf'), 'new-csrf'); return json({}); }
    if (url.pathname.endsWith('/nav')) return json(nav);
    throw new Error('Unexpected upstream');
  });
  try {
    await f.http.jar.setCookie('SESSDATA=old-session; Domain=.bilibili.com; Path=/; Secure', 'https://www.bilibili.com');
    await f.http.jar.setCookie('bili_jct=old-csrf; Domain=.bilibili.com; Path=/; Secure', 'https://www.bilibili.com');
    f.store.set('credentials', { jar: f.http.jar.serializeSync(), refreshToken: 'old-refresh', user: { mid: 42, name: '测试', avatar: '' } });
    // init performs one refresh; concurrent manual retries must share their own next transaction.
    await f.auth.init(); infoCalls = 0; refreshCalls = 0;
    await Promise.all([f.auth.refresh(), f.auth.refresh(), f.auth.refresh()]);
    assert.equal(infoCalls, 1); assert.equal(refreshCalls, 1); assert.equal(lastForm?.get('refresh_token'), 'new-refresh');
    assert.equal(f.store.get<{ refreshToken: string }>('credentials')?.refreshToken, 'new-refresh');
  } finally { await f.clean(); }
});
test('expired saved credentials are cleared; transient network failures preserve the encrypted session', async () => {
  let offline = true;
  const f = fixture(() => { if (offline) throw new Error('offline'); return json(undefined, -101); });
  try {
    f.store.set('credentials', { jar: f.http.jar.serializeSync(), user: { mid: 42, name: '测试', avatar: '' } }); await f.auth.init();
    assert.equal((await f.auth.state()).authenticated, true); assert(f.store.get('credentials'));
    offline = false; await f.auth.refresh(); assert.equal((await f.auth.state()).authenticated, false); assert.equal(f.store.get('credentials'), undefined);
  } finally { await f.clean(); }
});
test('encrypted store rejects a different key and does not expose plaintext fields', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'bilight-store-')), path = join(directory, 'store.sqlite');
  try {
    const store = new SecretStore(path, randomBytes(32)); store.set('credentials', { SESSDATA: 'do-not-leak-this-session' }); store.close();
    assert(!readFileSync(path).includes(Buffer.from('do-not-leak-this-session')));
    const wrong = new SecretStore(path, randomBytes(32)); try { assert.throws(() => wrong.get('credentials'), /无法解密/); } finally { wrong.close(); }
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
test('transport preserves redirect cookies while keeping credentials away from b23 short links', async () => {
  const calls: { host: string; cookie: string | null }[] = [];
  const http = new BiliHttp({ fetch: (async (value: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(value)); calls.push({ host: url.host, cookie: new Headers(init?.headers).get('cookie') });
    if (url.hostname === 'b23.tv') return new Response(null, { status: 302, headers: { location: 'https://www.bilibili.com/video/BV1234567890' } });
    return new Response(null, { headers: { 'set-cookie': 'bili_jct=next; Domain=.bilibili.com; Path=/; Secure' } });
  }) as typeof fetch });
  await http.jar.setCookie('SESSDATA=secret; Domain=.bilibili.com; Path=/; Secure', 'https://www.bilibili.com');
  const manual = await http.fetchWithCookies('https://b23.tv/test', { redirect: 'manual' }); assert.equal(manual.status, 302); assert.equal(calls.length, 1); assert.equal(calls[0].cookie, null);
  await http.fetchWithCookies('https://b23.tv/test'); assert.equal(calls.at(-1)?.cookie, 'SESSDATA=secret');
  assert.match(await http.jar.getCookieString('https://api.bilibili.com/'), /bili_jct=next/);
  await assert.rejects(http.fetchWithCookies('https://www.bilibili.com:444/'), (error: unknown) => error instanceof BiliError && error.code === 'INVALID_UPSTREAM');
});
test('WBI supports anonymous nav and signs a deterministic encoded query without leaking cookies', async () => {
  const http = new BiliHttp({ now: () => 1_700_000_000_000, fetch: (async (value: string | URL | Request) => {
    const url = new URL(String(value));
    if (url.pathname.endsWith('/nav')) return json({ isLogin: false, wbi_img: { img_url: 'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png', sub_url: 'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png' } }, -101);
    assert.equal(url.searchParams.get('wts'), '1700000000'); assert.match(url.searchParams.get('w_rid')!, /^[a-f0-9]{32}$/); assert(url.search.includes('hello%20world')); assert(!url.search.includes('hello+world')); return json({ ok: true });
  }) as typeof fetch });
  assert.deepEqual(await http.request('/x/web-interface/wbi/search/type', { query: { keyword: "hello world!" }, wbi: true }), { ok: true });
});
test('logout cannot be undone by an upstream Set-Cookie response that was already in flight', async () => {
  let release!: (response: Response) => void, started!: () => void;
  const began = new Promise<void>(resolve => { started = resolve; });
  const f = fixture(() => { started(); return new Promise<Response>(resolve => { release = resolve; }); });
  try {
    await f.auth.init(); await f.http.jar.setCookie('SESSDATA=old; Domain=.bilibili.com; Path=/; Secure', 'https://www.bilibili.com');
    const pending = f.http.fetchWithCookies('https://api.bilibili.com/x/request'); await began;
    await f.auth.logout(); release(new Response(null, { headers: { 'set-cookie': 'SESSDATA=late; Domain=.bilibili.com; Path=/; Secure' } })); await pending;
    assert.equal(await f.http.jar.getCookieString('https://api.bilibili.com'), ''); assert.equal(f.store.get('credentials'), undefined);
  } finally { await f.clean(); }
});

test('QR accepts the official biligame cross-domain result without requesting it or exposing credentials', async () => {
  const f = fixture((url, init) => {
    assert.notEqual(url.hostname, 'passport.biligame.com', 'the cross-domain URL must only be parsed locally');
    if (url.pathname.endsWith('/generate')) return json({ url: 'https://account.bilibili.com/scan', qrcode_key: 'fake-qr' });
    if (url.pathname.endsWith('/poll')) {
      const headers = new Headers({ 'content-type': 'application/json' });
      for (const [name, value] of [['SESSDATA', 'header-session'], ['bili_jct', 'header-csrf'], ['DedeUserID', '42']]) headers.append('set-cookie', `${name}=${value}; Domain=.bilibili.com; Path=/; Secure; HttpOnly`);
      return new Response(JSON.stringify({ code: 0, data: { code: 0, url: 'https://passport.biligame.com/crossDomain?SESSDATA=query-session&bili_jct=query-csrf&DedeUserID=42', refresh_token: 'fake-refresh' } }), { headers });
    }
    if (url.pathname.endsWith('/nav')) { const cookie = new Headers(init.headers).get('cookie') ?? ''; assert(cookie.includes('SESSDATA=header-session')); assert(!cookie.includes('query-session')); return json(nav); }
    throw new Error('Unexpected upstream');
  });
  try {
    await f.auth.init(); const qr = await f.auth.qrCreate(), result = await f.auth.qrPoll(qr.id);
    assert.deepEqual(result, { state: 'authenticated' }); assert.equal((await f.auth.state()).user?.mid, 42);
    assert(!JSON.stringify(result).includes('SESSDATA')); assert.equal(f.store.get<{ refreshToken: string }>('credentials')?.refreshToken, 'fake-refresh');
    await assert.rejects(f.http.fetchWithCookies('https://passport.biligame.com/crossDomain'), (error: unknown) => error instanceof BiliError && error.code === 'INVALID_UPSTREAM');
  } finally { await f.clean(); }
});

test('real QR callback ticket path cannot reject a freshly issued response session', async () => {
  const f = fixture((url, init) => {
    if (url.pathname.endsWith('/generate')) return json({ url: 'https://account.bilibili.com/scan', qrcode_key: 'fake-qr' });
    if (url.pathname.endsWith('/poll')) {
      const headers = new Headers({ 'content-type': 'application/json' });
      for (const [name, value] of [['SESSDATA', 'issued-session'], ['bili_jct', 'issued-csrf'], ['DedeUserID', '42']]) headers.append('set-cookie', `${name}=${value}; Domain=.bilibili.com; Path=/; Secure; HttpOnly`);
      return new Response(JSON.stringify({ code: 0, data: { code: 0, url: 'https://passport.biligame.com/x/passport-login/web/crossDomain?ticket=fake-ticket&gourl=https%3A%2F%2Fwww.bilibili.com&first_domain=.bilibili.com', refresh_token: 'fake-refresh' } }), { headers });
    }
    if (url.pathname.endsWith('/nav')) { assert.match(new Headers(init.headers).get('cookie') ?? '', /SESSDATA=issued-session/); return json(nav); }
    throw new Error('Only Bilibili poll and account validation may be requested');
  });
  try {
    await f.auth.init(); const qr = await f.auth.qrCreate();
    assert.deepEqual(await f.auth.qrPoll(qr.id), { state: 'authenticated' });
    assert.equal((await f.auth.state()).authenticated, true);
  } finally { await f.clean(); }
});

test('fresh response cookies need no usable SSO URL, while an old cookie alone never completes a new login', async () => {
  for (const sso of ['not-a-url', 'https://unrelated.example/unused', 'http://passport.biligame.com/x/passport-login/web/crossDomain']) {
    const f = fixture(url => {
      if (url.pathname.endsWith('/generate')) return json({ url: 'https://account.bilibili.com/scan', qrcode_key: 'fake-qr' });
      if (url.pathname.endsWith('/poll')) return json({ code: 0, url: sso }, 0, { 'set-cookie': 'SESSDATA=issued-session; Domain=.bilibili.com; Path=/; Secure; HttpOnly' });
      if (url.pathname.endsWith('/nav')) return json(nav);
      throw new Error('The SSO URL must never be requested');
    });
    try { await f.auth.init(); const qr = await f.auth.qrCreate(); assert.deepEqual(await f.auth.qrPoll(qr.id), { state: 'authenticated' }); }
    finally { await f.clean(); }
  }
  const f = fixture(url => url.pathname.endsWith('/generate') ? json({ url: 'https://account.bilibili.com/scan', qrcode_key: 'fake-qr' }) : json({ code: 0 }));
  try {
    await f.auth.init(); await f.http.jar.setCookie('SESSDATA=old-session; Domain=.bilibili.com; Path=/; Secure', 'https://www.bilibili.com');
    const qr = await f.auth.qrCreate(); await assert.rejects(f.auth.qrPoll(qr.id), (error: unknown) => error instanceof BiliError && error.code === 'INVALID_RESPONSE');
    assert.equal((await f.auth.state()).authenticated, false);
  } finally { await f.clean(); }
});

test('rejected or inapplicable response cookies cannot turn an old session into a new QR login', async () => {
  for (const issued of [
    'SESSDATA=issued-session; Domain=.example.com; Path=/; Secure',
    'SESSDATA=issued-session; Path=/; Secure',
    'SESSDATA=issued-session; Domain=.bilibili.com; Path=/passport; Secure',
    'SESSDATA=issued-session; Domain=.bilibili.com; Path=/; Max-Age=0; Secure',
  ]) {
    let navCalls = 0, acceptedNames: readonly string[] = [];
    const f = fixture(url => {
      if (url.pathname.endsWith('/generate')) return json({ url: 'https://account.bilibili.com/scan', qrcode_key: 'fake-qr' });
      if (url.pathname.endsWith('/poll')) return json({ code: 0 }, 0, { 'set-cookie': issued });
      if (url.pathname.endsWith('/nav')) { navCalls++; return json(nav); }
      throw new Error('Unexpected upstream');
    });
    try {
      await f.auth.init();
      await f.http.jar.setCookie('SESSDATA=old-session; Domain=.bilibili.com; Path=/; Secure', 'https://www.bilibili.com');
      await f.http.request('https://passport.bilibili.com/x/passport-login/web/qrcode/poll', { onResponseCookies: names => { acceptedNames = names; } });
      assert.deepEqual(acceptedNames, [], issued);
      const qr = await f.auth.qrCreate();
      await assert.rejects(f.auth.qrPoll(qr.id), (error: unknown) => error instanceof BiliError && error.code === 'INVALID_RESPONSE');
      assert.equal(navCalls, 0); assert.equal((await f.auth.state()).authenticated, false);
    } finally { await f.clean(); }
  }
});

test('QR completion can retry a transient nav failure without losing its opaque challenge', async () => {
  let navCalls = 0, pollCalls = 0;
  const f = fixture(url => {
    if (url.pathname.endsWith('/generate')) return json({ url: 'https://account.bilibili.com/scan', qrcode_key: 'fake-qr' });
    if (url.pathname.endsWith('/poll')) { pollCalls++; return json({ code: 0, url: 'https://passport.biligame.com/crossDomain?SESSDATA=retry-session&bili_jct=retry-csrf&DedeUserID=42', refresh_token: 'fake-refresh' }); }
    if (url.pathname.endsWith('/nav')) { if (++navCalls === 1) throw new Error('temporary offline'); return json(nav); }
    throw new Error('Unexpected upstream');
  });
  try {
    await f.auth.init(); const qr = await f.auth.qrCreate();
    await assert.rejects(f.auth.qrPoll(qr.id), (error: unknown) => error instanceof BiliError && error.code === 'UPSTREAM_UNAVAILABLE');
    assert.equal((await f.auth.state()).authenticated, false);
    assert.deepEqual(await f.auth.qrPoll(qr.id), { state: 'authenticated' }); assert.equal(pollCalls, 1);
  } finally { await f.clean(); }
});

test('SMS can finish from response cookies when the successful response has no exchange URL', async () => {
  const f = fixture((url, init) => {
    if (url.pathname.endsWith('/country/list')) return json({ common: [{ id: 1, cname: '中国大陆', country_id: '86' }] });
    if (url.pathname.endsWith('/captcha')) return json({ token: 'fake-token', geetest: { gt: 'fake-gt', challenge: 'fake-challenge' } });
    if (url.pathname.endsWith('/sms/send')) return json({ captcha_key: 'fake-sms' });
    if (url.pathname.endsWith('/login/sms')) {
      const headers = new Headers({ 'content-type': 'application/json' });
      for (const [name, value] of [['SESSDATA', 'sms-session'], ['bili_jct', 'sms-csrf'], ['DedeUserID', '42']]) headers.append('set-cookie', `${name}=${value}; Domain=.bilibili.com; Path=/; Secure; HttpOnly`);
      return new Response(JSON.stringify({ code: 0, data: { status: 0, refresh_token: 'fake-refresh' } }), { headers });
    }
    if (url.pathname.endsWith('/nav')) { assert.match(new Headers(init.headers).get('cookie') ?? '', /SESSDATA=sms-session/); return json(nav); }
    throw new Error('Unexpected upstream');
  });
  try {
    await f.auth.init(); const captcha = await f.auth.captcha();
    const ticket = await f.auth.sendSms({ challengeId: captcha.id, tel: '13800000000', cid: 1, challenge: 'final-challenge', validate: 'proof', seccode: 'proof' });
    assert.deepEqual(await f.auth.loginSms({ id: ticket.id, code: '123456' }), { state: 'authenticated' });
  } finally { await f.clean(); }
});

test('the biligame exception remains limited to server-only HTTPS crossDomain parsing', async () => {
  for (const exchange of ['http://passport.biligame.com/crossDomain', 'https://passport.biligame.com/other', 'https://passport.biligame.com.evil.example/crossDomain', 'https://user:pass@passport.biligame.com/crossDomain', 'https://passport.biligame.com:444/crossDomain']) {
    const f = fixture(url => url.pathname.endsWith('/generate') ? json({ url: 'https://account.bilibili.com/scan', qrcode_key: 'fake-qr' }) : json({ code: 0, url: `${exchange}?SESSDATA=fake-session` }));
    try { await f.auth.init(); const qr = await f.auth.qrCreate(); await assert.rejects(f.auth.qrPoll(qr.id), (error: unknown) => error instanceof BiliError && error.code === 'INVALID_RESPONSE'); assert.equal((await f.auth.state()).authenticated, false); }
    finally { await f.clean(); }
  }
  const f = fixture(() => json({ url: 'https://passport.biligame.com/crossDomain', qrcode_key: 'fake-qr' }));
  try { await f.auth.init(); await assert.rejects(f.auth.qrCreate(), (error: unknown) => error instanceof BiliError && error.code === 'INVALID_RESPONSE'); }
  finally { await f.clean(); }
});
