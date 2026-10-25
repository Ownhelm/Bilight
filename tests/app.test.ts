import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createApp } from '../server/app.js';
import { MediaRegistry, validateMediaUrl } from '../server/media.js';
import type { AuthService } from '../server/auth.js';
import { BiliGateway, type PlaybackSource } from '../server/gateway.js';
import type { BiliHttp } from '../server/transport.js';

const host = { host: '127.0.0.1:3880' };
const bvid = 'BV1xx411c7mD';
const source: PlaybackSource = { cid: 42, quality: 80, duration: 90, qualities: [{ id: 80, label: '1080P' }], subtitles: [], video: { id: 80, baseUrl: 'https://test.bilivideo.com/video.m4s?token=private', mimeType: 'video/mp4', codecs: 'avc1.640028', bandwidth: 100000, width: 1920, height: 1080, segmentBase: { initialization: '0-999', indexRange: '1000-2000' } }, audio: { id: 30280, baseUrl: 'https://test.bilivideo.com/audio.m4s?token=private', mimeType: 'audio/mp4', codecs: 'mp4a.40.2', bandwidth: 64000, segmentBase: { initialization: '0-999', indexRange: '1000-2000' } } };
const gateway = { resolve: async () => '/search?keyword=test', search: async () => ({ videos: [{ bvid, aid: 123, title: '视频', cover: 'https://i0.hdslb.com/cover.jpg', duration: 90, publishedAt: 1, owner: { mid: 1, name: 'UP', avatar: 'https://i0.hdslb.com/avatar.jpg' } }], users: [], page: 1, hasMore: false }), video: async () => ({ bvid, aid: 123, title: '视频', description: '', cover: '', owner: { mid: 1, name: 'UP', avatar: '' }, parts: [{ cid: 42, page: 1, title: 'P1', duration: 90 }], publishedAt: 1, views: 2 }), playback: async () => source } as unknown as BiliGateway;
const auth = { state: async () => ({ authenticated: false }), qrCreate: async () => ({ id: 'opaque', url: 'https://passport.bilibili.com/scan', expiresAt: 99 }), logout: async () => {} } as unknown as AuthService;

test('watching in Bilight reports to Bilibili and reads the same cloud history', async t => {
  let progress = 0, writes = 0;
  const remote = { ...gateway, reportHistory: async (_video: unknown, part: { cid: number }, value: number) => { assert.equal(part.cid, 42); writes++; progress = value; }, history: async () => ({ items: writes ? [{ bvid, aid: 123, cid: 42, page: 1, title: 'Cloud record', cover: '', owner: { mid: 1, name: 'UP', avatar: '' }, duration: 90, publishedAt: 1, viewedAt: 100, progress }] : [], hasMore: false }) } as unknown as BiliGateway;
  const logged = await createApp({ auth: { ...auth, state: async () => ({ authenticated: true, user: { mid: 7, name: 'Viewer', avatar: '' } }) } as AuthService, gateway: remote, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => logged.close());
  const initial = await logged.inject({ url: '/api/auth/state', headers: host });
  const headers = { ...host, cookie: String(initial.headers['set-cookie']).split(';')[0], origin: 'http://127.0.0.1:3880', 'x-bilight-request': '1' };
  assert.equal((await logged.inject({ method: 'POST', url: '/api/history', headers, payload: { bvid, cid: 42, progress: 23, accountMid: 7 } })).statusCode, 200);
  const result = await logged.inject({ url: '/api/history?limit=6', headers: host });
  assert.equal(result.statusCode, 200); assert.equal(result.json().items[0].progress, 23); assert.equal(writes, 1);
  assert.equal((await logged.inject({ url: '/api/history?source=local', headers: host })).statusCode, 400);
});

test('cloud history validates parts, ownership and CSRF and never falls back to a local copy', async t => {
  let mid = 7, writes = 0;
  const remote = { ...gateway, reportHistory: async () => { writes++; }, history: async () => { throw Object.assign(new Error('Cloud unavailable'), { code: 'HISTORY_UNAVAILABLE', status: 502 }); } } as unknown as BiliGateway;
  const logged = await createApp({ auth: { ...auth, state: async () => ({ authenticated: mid > 0, ...(mid > 0 ? { user: { mid, name: 'Viewer', avatar: '' } } : {}) }) } as AuthService, gateway: remote, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => logged.close());
  const initial = await logged.inject({ url: '/api/auth/state', headers: host });
  const headers = { ...host, cookie: String(initial.headers['set-cookie']).split(';')[0], origin: 'http://127.0.0.1:3880', 'x-bilight-request': '1' }, payload = { bvid, cid: 42, progress: 23, accountMid: 7 };
  for (const badHeaders of [{ ...headers, origin: 'https://evil.example' }, { ...headers, cookie: '' }]) assert.equal((await logged.inject({ method: 'POST', url: '/api/history', headers: badHeaders, payload })).statusCode, 403);
  for (const bad of [{ ...payload, cid: 999 }, { ...payload, progress: -1 }, { ...payload, progress: '23' }, { ...payload, completed: 'yes' }]) assert.equal((await logged.inject({ method: 'POST', url: '/api/history', headers, payload: bad })).statusCode, 400);
  assert.equal((await logged.inject({ method: 'POST', url: '/api/history', headers, payload: { ...payload, accountMid: 8 } })).statusCode, 409);
  assert.equal((await logged.inject({ method: 'POST', url: '/api/history', headers, payload })).statusCode, 200); assert.equal(writes, 1);
  assert.equal((await logged.inject({ url: '/api/history', headers: host })).statusCode, 502);
  mid = 8; assert.equal((await logged.inject({ method: 'POST', url: '/api/history', headers, payload })).statusCode, 409);
  mid = 0; assert.equal((await logged.inject({ url: '/api/history', headers: host })).statusCode, 401);
  assert.equal((await logged.inject({ method: 'POST', url: '/api/history', headers, payload })).statusCode, 401); assert.equal(writes, 1);
});

test('a slow old progress request cannot overwrite a newer cloud flush or cross accounts', async t => {
  let release: (() => void) | undefined, details = 0, mid = 7; const reports: number[] = [];
  const delayed = { ...gateway, video: async () => { if (++details === 1) await new Promise<void>(resolve => { release = resolve; }); return gateway.video(bvid); }, reportHistory: async (_v: unknown, _p: unknown, progress: number) => { reports.push(progress); } } as unknown as BiliGateway;
  const logged = await createApp({ auth: { ...auth, state: async () => ({ authenticated: true, user: { mid, name: 'Viewer', avatar: '' } }) } as AuthService, gateway: delayed, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => logged.close());
  const initial = await logged.inject({ url: '/api/auth/state', headers: host });
  const headers = { ...host, cookie: String(initial.headers['set-cookie']).split(';')[0], origin: 'http://127.0.0.1:3880', 'x-bilight-request': '1' }, payload = { bvid, cid: 42, progress: 1, accountMid: 7 };
  const old = logged.inject({ method: 'POST', url: '/api/history', headers, payload });
  while (!release) await new Promise(resolve => setImmediate(resolve));
  assert.equal((await logged.inject({ method: 'POST', url: '/api/history', headers, payload: { ...payload, progress: 24 } })).statusCode, 200);
  release(); assert.equal((await old).statusCode, 200); assert.deepEqual(reports, [24]);
  details = 0; release = undefined;
  const changed = logged.inject({ method: 'POST', url: '/api/history', headers, payload });
  while (!release) await new Promise(resolve => setImmediate(resolve));
  mid = 8; (release as () => void)(); assert.equal((await changed).statusCode, 409); assert.deepEqual(reports, [24]);
});

test('an in-flight cloud write completes before the newer pause progress is sent', async t => {
  let release: (() => void) | undefined;
  const reports: number[] = [];
  const remote = { ...gateway, reportHistory: async (_v: unknown, _p: unknown, progress: number) => {
    reports.push(progress);
    if (reports.length === 1) await new Promise<void>(resolve => { release = resolve; });
  } } as unknown as BiliGateway;
  const logged = await createApp({ auth: { ...auth, state: async () => ({ authenticated: true, user: { mid: 7, name: 'Viewer', avatar: '' } }) } as AuthService, gateway: remote, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => logged.close());
  const initial = await logged.inject({ url: '/api/auth/state', headers: host });
  const headers = { ...host, cookie: String(initial.headers['set-cookie']).split(';')[0], origin: 'http://127.0.0.1:3880', 'x-bilight-request': '1' };
  const first = logged.inject({ method: 'POST', url: '/api/history', headers, payload: { bvid, cid: 42, progress: 1, accountMid: 7 } });
  while (!release) await new Promise(resolve => setImmediate(resolve));
  const last = logged.inject({ method: 'POST', url: '/api/history', headers, payload: { bvid, cid: 42, progress: 20, accountMid: 7 } });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(reports, [1]);
  release(); assert.equal((await first).statusCode, 200); assert.equal((await last).statusCode, 200);
  assert.deepEqual(reports, [1, 20]);
});

test('history requires login and history/collections expose only registered local images', async t => {
  let historyCalls = 0;
  const localGateway = { ...gateway, history: async () => { historyCalls++; return { items: [{ bvid, aid: 1, title: 'Watched', cover: 'https://i0.hdslb.com/history.jpg', owner: { mid: 7, name: 'UP', avatar: 'https://i0.hdslb.com/avatar.jpg' }, progress: 15, page: 2, cid: 42, duration: 60, viewedAt: 100 }], hasMore: false }; }, creatorCollections: async () => ({ items: [{ id: 1, mid: 7, kind: 'season', title: 'Lessons', cover: 'https://i0.hdslb.com/collection.jpg', count: 2 }], hasMore: false }), collection: async () => ({ collection: { id: 1, mid: 7, kind: 'season', title: 'Lessons', cover: 'https://i0.hdslb.com/collection.jpg' }, items: [], hasMore: false }) } as unknown as BiliGateway;
  const anonymous = await createApp({ auth, gateway: localGateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => anonymous.close());
  assert.equal((await anonymous.inject({ url: '/api/history', headers: host })).statusCode, 401); assert.equal(historyCalls, 0);
  const logged = await createApp({ auth: { ...auth, state: async () => ({ authenticated: true }) } as AuthService, gateway: localGateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => logged.close());
  for (const url of ['/api/history', '/api/creators/7/collections', '/api/creators/7/collections/season/1']) { const result = await logged.inject({ url, headers: host }); assert.equal(result.statusCode, 200); assert.ok(!result.body.includes('hdslb.com')); assert.match(result.body, /\/api\/media\//); }
  assert.equal((await logged.inject({ url: '/api/history?cursor=https://evil.example', headers: host })).statusCode, 400);
  assert.equal((await logged.inject({ url: '/api/creators/7/collections/arbitrary/1', headers: host })).statusCode, 400);
  assert.equal((await logged.inject({ method: 'POST', url: '/api/history', headers: host })).statusCode, 403);
});

test('triple requires login, signed local cookies and exact origin; a read never triggers interaction', async t => {
  let writes = 0, reads = 0;
  const localGateway = { ...gateway, engagement: async () => { reads++; return { liked: false, coins: 0, favorited: false }; }, triple: async () => { writes++; return { state: { liked: true, coins: 2, favorited: true }, complete: true }; } } as unknown as BiliGateway;
  const logged = await createApp({ auth: { ...auth, state: async () => ({ authenticated: true }) } as AuthService, gateway: localGateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => logged.close());
  const initial = await logged.inject({ url: `/api/videos/${bvid}/engagement`, headers: host }); assert.equal(initial.statusCode, 200); assert.equal(writes, 0); assert.equal(reads, 1);
  const cookie = String(initial.headers['set-cookie']).split(';')[0];
  const headers = { ...host, cookie, origin: 'http://127.0.0.1:3880', 'x-bilight-request': '1' };
  assert.equal((await logged.inject({ method: 'POST', url: `/api/videos/${bvid}/triple`, headers: { ...headers, origin: 'https://attacker.example' } })).statusCode, 403);
  assert.equal((await logged.inject({ method: 'POST', url: `/api/videos/${bvid}/triple`, headers: { ...headers, cookie: '' } })).statusCode, 403);
  assert.equal(writes, 0);
  assert.equal((await logged.inject({ method: 'POST', url: '/api/videos/not-a-bv/triple', headers })).statusCode, 400);
  const result = await logged.inject({ method: 'POST', url: `/api/videos/${bvid}/triple`, headers }); assert.equal(result.statusCode, 200); assert.equal(result.json().complete, true); assert.equal(writes, 1);
  const anonymous = await createApp({ auth, gateway: localGateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => anonymous.close());
  const visit = await anonymous.inject({ url: `/api/videos/${bvid}/engagement`, headers: host }); assert.equal(visit.statusCode, 401);
  assert.equal((await anonymous.inject({ method: 'POST', url: `/api/videos/${bvid}/triple`, headers: { ...headers, cookie: String(visit.headers['set-cookie']).split(';')[0] } })).statusCode, 401); assert.equal(writes, 1);
});

test('individual interactions and folder reads require login; writes retain signed cookie and origin protection', async t => {
  let writes = 0;
  const localGateway = { ...gateway, favoriteFolders: async () => [{ id: 1, title: 'My folder', count: 2, selected: false }], interact: async () => { writes++; return { liked: true, coins: 0, favorited: false }; } } as unknown as BiliGateway;
  const logged = await createApp({ auth: { ...auth, state: async () => ({ authenticated: true }) } as AuthService, gateway: localGateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => logged.close());
  const initial = await logged.inject({ url: `/api/videos/${bvid}/favorite-folders`, headers: host }); assert.equal(initial.statusCode, 200); assert.equal(initial.json().items.length, 1); assert.equal(writes, 0);
  const headers = { ...host, cookie: String(initial.headers['set-cookie']).split(';')[0], origin: 'http://127.0.0.1:3880', 'x-bilight-request': '1' }, payload = { type: 'like', liked: true };
  for (const bad of [{ ...headers, origin: 'https://evil.example' }, { ...headers, cookie: '' }]) assert.equal((await logged.inject({ method: 'POST', url: `/api/videos/${bvid}/interaction`, headers: bad, payload })).statusCode, 403);
  assert.equal(writes, 0);
  const result = await logged.inject({ method: 'POST', url: `/api/videos/${bvid}/interaction`, headers, payload }); assert.equal(result.statusCode, 200); assert.equal(writes, 1);
  const anonymous = await createApp({ auth, gateway: localGateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => anonymous.close());
  assert.equal((await anonymous.inject({ url: `/api/videos/${bvid}/favorite-folders`, headers: host })).statusCode, 401);
});

test('coin dialogs and folder creation are wired to authenticated read and protected write routes', async t => {
  let creations = 0;
  const localGateway = { ...gateway, coinInfo: async () => ({ state: { liked: false, coins: 0, favorited: false }, coinLimit: 1 }), coinExperience: async () => 40, createFavoriteFolder: async (_bvid: string, title: string) => { creations++; assert.equal(title, 'Study'); return { id: 9, title, count: 0, selected: false }; } } as unknown as BiliGateway;
  const logged = await createApp({ auth: { ...auth, state: async () => ({ authenticated: true }) } as AuthService, gateway: localGateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => logged.close());
  const read = await logged.inject({ url: `/api/videos/${bvid}/coin-info`, headers: host }); assert.equal(read.statusCode, 200); assert.equal(read.json().coinLimit, 1);
  assert.deepEqual((await logged.inject({ url: `/api/videos/${bvid}/coin-experience`, headers: host })).json(), { experience: 40 });
  const headers = { ...host, cookie: String(read.headers['set-cookie']).split(';')[0], origin: 'http://127.0.0.1:3880', 'x-bilight-request': '1' }, payload = { title: 'Study' };
  assert.equal((await logged.inject({ method: 'POST', url: `/api/videos/${bvid}/favorite-folders`, headers: { ...headers, origin: 'https://evil.example' }, payload })).statusCode, 403); assert.equal(creations, 0);
  assert.equal((await logged.inject({ method: 'POST', url: `/api/videos/${bvid}/favorite-folders`, headers, payload })).statusCode, 200); assert.equal(creations, 1);
  const anonymous = await createApp({ auth, gateway: localGateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => anonymous.close());
  assert.equal((await anonymous.inject({ url: `/api/videos/${bvid}/coin-info`, headers: host })).statusCode, 401);
});

test('loopback host enforcement prevents DNS rebinding and cross-origin login mutation', async t => {
  const app = await createApp({ auth, gateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => app.close());
  assert.equal((await app.inject({ url: '/health', headers: { host: 'attacker.example' } })).statusCode, 403);
  const initial = await app.inject({ url: '/api/auth/state', headers: host });
  const setCookie = String(initial.headers['set-cookie']);
  assert.match(setCookie, /HttpOnly/); assert.match(setCookie, /SameSite=Strict/);
  assert.equal((await app.inject({ method: 'POST', url: '/api/auth/qr', headers: { ...host, origin: 'https://attacker.example', cookie: setCookie.split(';')[0], 'x-bilight-request': '1' } })).statusCode, 403);
  assert.equal((await app.inject({ method: 'POST', url: '/api/auth/qr', headers: { ...host, origin: 'http://127.0.0.1:3880', cookie: setCookie.split(';')[0], 'x-bilight-request': '1' } })).statusCode, 200);
  assert.equal((await app.inject({ method: 'POST', url: '/api/auth/qr', headers: { ...host, origin: 'http://127.0.0.1:3880', 'x-bilight-request': '1' } })).statusCode, 403);
});

test('the exact OrbStack domain supports reads and signed same-origin mutations over HTTP and HTTPS', async t => {
  const app = await createApp({ auth, gateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => app.close());
  const domain = { host: 'bilibili.local' };
  assert.equal((await app.inject({ url: '/health', headers: domain })).statusCode, 200);
  const initial = await app.inject({ url: '/api/auth/state', headers: domain });
  assert.equal(initial.statusCode, 200);
  assert.deepEqual(initial.json(), { authenticated: false });
  const cookie = String(initial.headers['set-cookie']).split(';')[0];
  for (const origin of ['http://bilibili.local', 'https://bilibili.local']) {
    assert.equal((await app.inject({ method: 'POST', url: '/api/auth/qr', headers: { ...domain, origin, cookie, 'x-bilight-request': '1' } })).statusCode, 200);
    assert.equal((await app.inject({ method: 'POST', url: '/api/auth/qr', headers: { ...domain, origin, 'x-bilight-request': '1' } })).statusCode, 403);
    assert.equal((await app.inject({ method: 'POST', url: '/api/auth/qr', headers: { ...domain, origin, cookie } })).statusCode, 403);
  }
});

test('OrbStack domain access keeps exact host and origin checks against lookalikes and external sites', async t => {
  const app = await createApp({ auth, gateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => app.close());
  const initial = await app.inject({ url: '/api/auth/state', headers: { host: 'bilibili.local' } });
  const cookie = String(initial.headers['set-cookie']).split(';')[0];
  for (const hostname of ['bilibili.local.attacker.example', 'www.bilibili.local', 'other.local', 'bilibili.local:3880', 'bilibili.com']) {
    assert.equal((await app.inject({ url: '/health', headers: { host: hostname } })).statusCode, 403);
    assert.equal((await app.inject({ url: '/api/auth/state', headers: { host: hostname } })).statusCode, 403);
  }
  for (const origin of ['https://bilibili.local.attacker.example', 'http://www.bilibili.local', 'http://other.local', 'http://bilibili.local:3880', 'https://attacker.example', 'https://www.bilibili.com']) {
    assert.equal((await app.inject({ method: 'POST', url: '/api/auth/qr', headers: { host: 'bilibili.local', origin, cookie, 'x-bilight-request': '1' } })).statusCode, 403);
  }
});

test('API exposes only local image/stream identifiers and validates part ownership', async t => {
  const app = await createApp({ auth, gateway, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => app.close());
  const result = await app.inject({ url: '/api/search?keyword=test', headers: host });
  assert.equal(result.statusCode, 200);
  assert.match(result.json().videos[0].cover, /^\/api\/media\//);
  assert.ok(!result.body.includes('hdslb.com'));
  const playback = await app.inject({ url: `/api/videos/${bvid}/playback?cid=42`, headers: host });
  assert.equal(playback.statusCode, 200);
  assert.match(playback.json().manifestUrl, /manifest.mpd$/);
  assert.ok(!playback.body.includes('private'));
  assert.equal((await app.inject({ url: `/api/videos/${bvid}/playback?cid=999`, headers: host })).statusCode, 400);
  assert.equal((await app.inject({ url: '/api/following', headers: host })).statusCode, 401);
  for (const route of ['/api/recommend', '/api/popular', '/api/trending']) assert.equal((await app.inject({ url: route, headers: host })).statusCode, 404);
});

test('playback route requests the highest quality by default and preserves an explicit selection', async t => {
  const qualities: number[] = [];
  const chosen = { ...gateway, playback: async (_bvid: string, _cid: number, quality: number) => { qualities.push(quality); return source; } } as unknown as BiliGateway;
  const app = await createApp({ auth, gateway: chosen, key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => app.close());
  assert.equal((await app.inject({ url: `/api/videos/${bvid}/playback?cid=42`, headers: host })).statusCode, 200);
  assert.equal((await app.inject({ url: `/api/videos/${bvid}/playback?cid=42&quality=64`, headers: host })).statusCode, 200);
  assert.deepEqual(qualities, [127, 64]);
});

test('detail, playback, comments and danmaku routes reuse one session-scoped detail request without skipping part checks', async t => {
  let details = 0;
  const transport = {
    request: async (url: string) => {
      if (url.endsWith('/view')) { details++; return { aid: 123, pages: [{ cid: 42, page: 1 }] }; }
      if (url.endsWith('/playurl')) return { dash: { duration: 90, video: [{ ...source.video, SegmentBase: source.video!.segmentBase }], audio: [{ ...source.audio, SegmentBase: source.audio!.segmentBase }] } };
      if (url.endsWith('/main')) return { replies: [], cursor: { is_end: true, all_count: 0 } };
      return {};
    },
    fetchWithCookies: async () => new Response('<i></i>'),
  } as unknown as BiliHttp;
  const app = await createApp({ auth, gateway: new BiliGateway(transport), key: randomBytes(32), staticDir: '/nonexistent' }); t.after(() => app.close());
  assert.equal((await app.inject({ url: `/api/videos/${bvid}`, headers: host })).statusCode, 200);
  const responses = await Promise.all(['playback?cid=42', 'comments', 'danmaku?cid=42'].map(route => app.inject({ url: `/api/videos/${bvid}/${route}`, headers: host })));
  assert.deepEqual(responses.map(response => response.statusCode), [200, 200, 200]);
  assert.equal(details, 1);
  for (const route of ['playback', 'danmaku']) assert.equal((await app.inject({ url: `/api/videos/${bvid}/${route}?cid=999`, headers: host })).statusCode, 400);
  assert.equal(details, 1);
});

test('account avatars accept the real CDN image/jpg MIME alias through the local proxy', async t => {
  const avatar = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2Q==', 'base64');
  const signedIn = { state: async () => ({ authenticated: true, user: { mid: 42, name: '测试账号', avatar: 'https://i0.hdslb.com/bfs/face/avatar.jpg' } }) } as unknown as AuthService;
  const media = new MediaRegistry(gateway, (async () => new Response(avatar, { headers: { 'Content-Type': 'image/jpg', 'Content-Length': String(avatar.length) } })) as typeof fetch);
  const app = await createApp({ auth: signedIn, gateway, media, key: randomBytes(32), staticDir: '/nonexistent' });
  t.after(() => app.close());
  const state = await app.inject({ url: '/api/auth/state', headers: host });
  const path = state.json().user.avatar;
  assert.match(path, /^\/api\/media\//);
  const response = await app.inject({ url: path, headers: host });
  assert.equal(response.statusCode, 200);
  assert.equal(response.headers['content-type'], 'image/jpeg');
  assert.deepEqual(response.rawPayload, avatar);
  assert.equal(response.headers['x-content-type-options'], 'nosniff');
});

test('media proxy preserves Range and partial response without forwarding cookies', async () => {
  let seen: RequestInit | undefined;
  const media = new MediaRegistry(gateway, (async (_url, init) => { seen = init; return new Response('data', { status: 206, headers: { 'Content-Range': 'bytes 0-3/100', 'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes' } }); }) as typeof fetch);
  const path = media.register(source.video!.baseUrl, 'video');
  const result = await media.fetch(path.split('/').pop()!, 'bytes=0-3');
  assert.equal(result!.response.status, 206); assert.equal(result!.response.headers.get('content-range'), 'bytes 0-3/100');
  assert.equal(new Headers(seen!.headers).get('Range'), 'bytes=0-3'); assert.equal(new Headers(seen!.headers).get('Cookie'), null);
});

test('proxy refuses arbitrary hosts and unsafe redirects, and accepts only registered resource IDs', async () => {
  for (const url of ['http://test.bilivideo.com/x', 'https://127.0.0.1/x', 'https://test.bilivideo.com.evil.test/x', 'https://user:pass@test.bilivideo.com/x', 'https://test.bilivideo.com:444/x']) assert.throws(() => validateMediaUrl(url, 'video'));
  const media = new MediaRegistry(gateway, (async () => new Response(null, { status: 302, headers: { location: 'http://169.254.169.254/' } })) as typeof fetch);
  assert.equal(await media.fetch('not-an-id'), undefined);
  const path = media.register(source.video!.baseUrl, 'video');
  await assert.rejects(media.fetch(path.split('/').pop()!));
  await assert.rejects(media.fetch(path.split('/').pop()!, 'bytes=0-2,4-8'));
});

test('expired media is renewed only once and the manifest contains same-origin ranges', async () => {
  let fetches = 0, renewed = 0;
  const media = new MediaRegistry(gateway, (async () => ++fetches === 1 ? new Response(null, { status: 403 }) : new Response('ok', { status: 206 })) as typeof fetch);
  const path = media.register(source.video!.baseUrl, 'video', async () => { renewed++; return 'https://test.bilivideo.com/new.m4s'; });
  assert.equal((await media.fetch(path.split('/').pop()!))!.response.status, 206); assert.equal(renewed, 1);
  const playback = media.playback(source, bvid);
  const id = playback.manifestUrl!.split('/')[3];
  const mpd = media.manifest(id)!;
  assert.match(mpd, /indexRange="1000-2000"/); assert.match(mpd, /audio\/mp4/); assert.ok(!mpd.includes('bilivideo.com')); assert.ok(!mpd.includes('private'));
  const silent = media.playback({ ...source, audio: undefined }, bvid);
  assert.ok(media.manifest(silent.manifestUrl!.split('/')[3]));
});

test('subtitles become inert VTT text with valid cue times', async () => {
  const media = new MediaRegistry(gateway, (async () => Response.json({ body: [{ from: 1.25, to: 3.5, content: '<script>alert(1)</script>' }, { from: 5, to: 4, content: 'invalid' }] })) as typeof fetch);
  const path = media.register('https://aisubtitle.hdslb.com/sub.json', 'subtitle');
  const vtt = await media.subtitle(path.split('/').pop()!);
  assert.match(vtt!, /00:00:01.250 --> 00:00:03.500/); assert.ok(!vtt!.includes('<script>')); assert.ok(!vtt!.includes('invalid'));
});
