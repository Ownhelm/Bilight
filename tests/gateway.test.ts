import test from 'node:test';
import assert from 'node:assert/strict';
import { CookieJar } from 'tough-cookie';
import { BiliGateway } from '../server/gateway.js';
import { BiliError, type BiliHttp, type BiliRequestOptions } from '../server/transport.js';

const BV1 = 'BV0000000001', BV2 = 'BV0000000002', BV3 = 'BV0000000003';
type Request = { url: string; options: BiliRequestOptions };
function fixture(handler: (request: Request) => unknown | Promise<unknown>, fetcher?: (url: string, init?: RequestInit) => Response | Promise<Response>) {
  const calls: Request[] = [], fetches: { url: string; init?: RequestInit }[] = [];
  const transport = {
    jar: new CookieJar(),
    async ensureDeviceCookies() {},
    async request<T>(url: string, options: BiliRequestOptions = {}): Promise<T> { const request = { url, options }; calls.push(request); return await handler(request) as T; },
    async fetchWithCookies(url: string, init?: RequestInit) { fetches.push({ url, init }); if (!fetcher) throw new Error('Unexpected fetch'); return fetcher(url, init); },
  } as unknown as BiliHttp;
  return { gateway: new BiliGateway(transport), transport, calls, fetches };
}
function post(bvid: string, mid: number, publishedAt: number, overrides: Record<string, unknown> = {}) {
  return { type: 'DYNAMIC_TYPE_AV', modules: { module_author: { mid, name: 'Followed creator', face: '//i0.hdslb.com/avatar.jpg', pub_ts: publishedAt }, module_dynamic: { major: { type: 'MAJOR_TYPE_ARCHIVE', archive: { aid: Number(bvid.slice(-1)), bvid, title: '<em>Video</em>', cover: '//i0.hdslb.com/a.jpg', duration_text: '01:25', stat: { play: '1.2万' } } } } }, ...overrides };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}
const track = (id: number, codecs: string, bandwidth = 1000) => ({ id, codecs, bandwidth, base_url: `https://upos-sz-mirrorcos.bilivideo.com/${id}.m4s`, backup_url: ['//backup.bilivideo.com/track.m4s'], mime_type: codecs.startsWith('avc') ? 'video/mp4' : 'audio/mp4', segment_base: { initialization: '0-999', index_range: '1000-2000' }, width: 1920, height: 1080, frame_rate: '30' });

const historyEntry = (bvid: string, viewedAt: number, progress = 15) => ({ title: '<b>Watched</b>', cover: '//i0.hdslb.com/history.jpg', author_name: 'Teacher', author_mid: 7, author_face: '//i0.hdslb.com/avatar.jpg', duration: 60, view_at: viewedAt, progress, uri: 'https://untrusted.example/', history: { oid: 42, bvid, cid: 52, page: 2, part: 'Part 2', business: 'archive' } });
const collectionMeta = (kind: 'season' | 'series', id: number, mid = 7) => ({ mid, [kind === 'season' ? 'season_id' : 'series_id']: id, name: '<b>Lessons</b>', description: '<script>bad()</script>Read in order', total: 31, cover: '//i0.hdslb.com/collection.jpg' });

test('history reads only explicit account history, preserves progress and uses the real opaque cursor', async () => {
  const next = { max: 999, view_at: 80, business: 'archive' };
  const { gateway, calls } = fixture(() => ({ list: [historyEntry(BV1, 100), { ...historyEntry(BV3, 300), history: { business: 'live', bvid: BV3 } }, historyEntry(BV2, 90, -1), historyEntry(BV1, 100)], cursor: next }));
  const result = await gateway.history(undefined, 6);
  assert.deepEqual(result.items.map(item => item.bvid), [BV1, BV2]); assert.equal(result.items[0].progress, 15); assert.equal(result.items[1].progress, -1);
  assert.equal(result.items[0].page, 2); assert.equal(result.items[0].cid, 52); assert.equal(result.items[0].title, 'Watched'); assert.equal(result.hasMore, true);
  assert.deepEqual(calls[0].options.query, { ps: 6, type: 'archive' }); assert.match(calls[0].url, /history\/cursor$/);
  await gateway.history(result.nextCursor);
  assert.deepEqual(calls[1].options.query, { ...next, ps: 20, type: 'archive' });
  assert.ok(!JSON.stringify(result).includes('untrusted.example')); assert.ok(calls.every(call => !/recommend|rcmd|popular/.test(call.url)));
});

test('history distinguishes empty from malformed data and rejects unsafe cursors and late account results', async () => {
  const empty = fixture(() => ({ list: [], cursor: { max: 0, view_at: 0, business: '' } }));
  assert.deepEqual(await empty.gateway.history(), { items: [], hasMore: false });
  for (const cursor of ['https://evil.example', Buffer.from('{"max":-1}').toString('base64url'), 'a'.repeat(601)]) await assert.rejects(empty.gateway.history(cursor), { code: 'INVALID_INPUT' });
  assert.equal(empty.calls.length, 1);
  await assert.rejects(fixture(() => ({ cursor: {} })).gateway.history(), { code: 'HISTORY_UNAVAILABLE' });
  const changed = fixture(() => { changed.transport.jar = new CookieJar(); return { list: [historyEntry(BV1, 100)], cursor: {} }; });
  await assert.rejects(changed.gateway.history(), { code: 'LOGIN_REQUIRED' });
});

test('collection catalog distinguishes seasons and series, uses actual covers and does not fetch each playlist', async () => {
  const { gateway, calls } = fixture(() => ({ items_lists: { page: { page_num: 1, page_size: 12, total: 25 }, seasons_list: [{ meta: collectionMeta('season', 10) }], series_list: [{ meta: { ...collectionMeta('series', 11), cover: '' }, archives: [{ pic: '//i0.hdslb.com/first.jpg' }] }] } }));
  const result = await gateway.creatorCollections(7);
  assert.deepEqual(result.items.map(item => [item.kind, item.id]), [['season', 10], ['series', 11]]); assert.equal(result.items[0].title, 'Lessons'); assert.equal(result.items[0].description, 'Read in order'); assert.equal(result.items[1].cover, 'https://i0.hdslb.com/first.jpg');
  assert.equal(result.hasMore, true); assert.equal(calls.length, 1); assert.deepEqual(calls[0].options.query, { mid: 7, page_num: 1, page_size: 12 });
  assert.equal(calls[0].options.headers?.referer, 'https://space.bilibili.com/7/lists');
});

test('season pages keep the returned playlist order and validate owner and collection identity', async () => {
  const { gateway, calls } = fixture(() => ({ meta: collectionMeta('season', 10), page: { page_num: 1, page_size: 30, total: 31 }, archives: [{ bvid: BV2, aid: 2, title: 'Second', duration: 60, pubdate: 5 }, { bvid: BV1, aid: 1, title: 'First', duration: 60, pubdate: 50 }] }));
  const result = await gateway.collection(7, 'season', 10);
  assert.deepEqual(result.items.map(item => item.bvid), [BV2, BV1]); assert.equal(result.hasMore, true); assert.equal(result.items[0].owner.mid, 7);
  assert.deepEqual(calls[0].options.query, { mid: 7, season_id: 10, sort_reverse: false, page_num: 1, page_size: 30 });
  await assert.rejects(gateway.collection(7, 'season', 20), { code: 'COLLECTION_UNAVAILABLE' });
  await assert.rejects(gateway.collection(8, 'season', 10), { code: 'COLLECTION_UNAVAILABLE' });
});

test('series pages fetch metadata and archives only for the chosen list and reject incomplete catalogs', async () => {
  const { gateway, calls } = fixture(({ url }) => url.endsWith('/series/series') ? { meta: collectionMeta('series', 11) } : { page: { num: 2, size: 30, total: 61 }, archives: [{ bvid: BV1, aid: 1, title: 'Episode' }] });
  const result = await gateway.collection(7, 'series', 11, 2);
  assert.equal(result.collection.kind, 'series'); assert.equal(result.collection.count, 61); assert.equal(result.hasMore, true); assert.equal(calls.length, 2);
  assert.deepEqual(calls[1].options.query, { mid: 7, series_id: 11, only_normal: true, sort: 'desc', pn: 2, ps: 30 });
  await assert.rejects(fixture(() => ({ items_lists: { page: { total: 0 }, seasons_list: [] } })).gateway.creatorCollections(7), { code: 'COLLECTIONS_UNAVAILABLE' });
  await assert.rejects(gateway.collection(7, 'other' as never, 11), { code: 'INVALID_INPUT' });
});

async function loginFixture(transport: BiliHttp) {
  await transport.jar.setCookie('SESSDATA=fixture-session; Domain=.bilibili.com; Secure; Path=/', 'https://api.bilibili.com/');
  await transport.jar.setCookie('bili_jct=fixture-csrf; Domain=.bilibili.com; Secure; Path=/', 'https://api.bilibili.com/');
  await transport.jar.setCookie('DedeUserID=7; Domain=.bilibili.com; Secure; Path=/', 'https://api.bilibili.com/');
}

test('history reporting sends only validated part progress to the official dual-client endpoint', async () => {
  const { gateway, transport, calls } = fixture(() => undefined);
  await loginFixture(transport);
  const video = { bvid: BV1, aid: 42, title: 'Actual video', description: '', cover: '', owner: { mid: 7, name: 'UP', avatar: '' }, publishedAt: 1, views: 0, parts: [{ cid: 52, page: 2, title: 'Part 2', duration: 60 }] };
  await gateway.reportHistory(video, video.parts[0], 70);
  assert.equal(calls.length, 1); assert.match(calls[0].url, /x\/v2\/history\/report$/);
  assert.deepEqual(calls[0].options.form, { aid: 42, cid: 52, progress: 60, csrf: 'fixture-csrf' });
  for (const progress of [-1, NaN, Infinity]) await assert.rejects(gateway.reportHistory(video, video.parts[0], progress), { code: 'INVALID_PROGRESS' });
  await assert.rejects(gateway.reportHistory(video, { ...video.parts[0], cid: 999 }, 10), { code: 'INVALID_PROGRESS' });
  assert.equal(calls.length, 1);
});

test('a failed history upload is not retried or claimed as saved', async () => {
  const { gateway, transport, calls } = fixture(() => { throw new BiliError('UPSTREAM_UNAVAILABLE', 'Network failed'); });
  await loginFixture(transport);
  const video = { bvid: BV1, aid: 42, title: 'Video', description: '', cover: '', owner: { mid: 7, name: 'UP', avatar: '' }, publishedAt: 1, views: 0, parts: [{ cid: 52, page: 1, title: 'Part', duration: 60 }] };
  await assert.rejects(gateway.reportHistory(video, video.parts[0], 12), { code: 'UPSTREAM_UNAVAILABLE' });
  assert.equal(calls.length, 1);
});

test('individual likes can be cancelled, and coins target a total without repeating completed writes', async () => {
  const state = { like: false, coin: 0, favorite: false };
  const { gateway, transport, calls } = fixture(({ url, options }) => {
    if (url.endsWith('/archive/like')) { state.like = options.form?.like === 1; return null; }
    if (url.endsWith('/coin/add')) { state.coin += Number(options.form?.multiply); return { like: false }; }
    return { ...state };
  });
  gateway.video = async () => ({ aid: 42, interaction: { coinLimit: 2 } } as never); await loginFixture(transport);
  assert.equal((await gateway.interact(BV1, { type: 'like', liked: true })).liked, true);
  await gateway.interact(BV1, { type: 'like', liked: true });
  assert.equal(calls.filter(call => call.options.method === 'POST').length, 1);
  assert.equal((await gateway.interact(BV1, { type: 'like', liked: false })).liked, false);
  await gateway.interact(BV1, { type: 'coin', coins: 1 }); await gateway.interact(BV1, { type: 'coin', coins: 2 }); await gateway.interact(BV1, { type: 'coin', coins: 2 });
  const coins = calls.filter(call => call.url.endsWith('/coin/add'));
  assert.equal(coins.length, 2); assert.deepEqual(coins.map(call => call.options.form?.multiply), [1, 1]);
  assert.deepEqual(coins[0].options.form, { bvid: BV1, multiply: 1, select_like: 0, csrf: 'fixture-csrf' });
  await assert.rejects(gateway.interact(BV1, { type: 'coin', coins: 3 } as never), { code: 'INVALID_INPUT' });
});

test('individual actions coalesce identical clicks and exclude triple or conflicting actions on the same video', async () => {
  const gate = deferred<void>(); let liked = false;
  const { gateway, transport, calls } = fixture(async ({ options }) => {
    if (options.method === 'POST') { await gate.promise; liked = true; return null; }
    return { like: liked, coin: 0, favorite: false };
  });
  await loginFixture(transport);
  const first = gateway.interact(BV1, { type: 'like', liked: true }), duplicate = gateway.interact(BV1, { type: 'like', liked: true });
  await assert.rejects(gateway.interact(BV1, { type: 'coin', coins: 2 }), { code: 'INTERACTION_BUSY' });
  await assert.rejects(gateway.triple(BV1), { code: 'INTERACTION_BUSY' });
  gate.resolve(); assert.deepEqual(await first, await duplicate); assert.equal(calls.filter(call => call.options.method === 'POST').length, 1);
});

test('favorite updates validate owned folders, apply only differences and confirm the saved selection', async () => {
  let selected = [10];
  const { gateway, transport, calls } = fixture(({ url, options }) => {
    if (url.endsWith('/list-all')) return { count: 2, list: [10, 20].map(id => ({ id, mid: 7, title: '<b>Folder</b>', media_count: 3, fav_state: selected.includes(id) ? 1 : 0 })) };
    if (url.endsWith('/resource/deal')) { selected = String(options.form?.add_media_ids).split(',').map(Number); return { success_num: 1 }; }
    return { like: false, coin: 0, favorite: selected.length > 0 };
  });
  gateway.video = async () => ({ aid: 42 } as never); await loginFixture(transport);
  const folders = await gateway.favoriteFolders(BV1); assert.equal(folders[0].title, 'Folder'); assert.equal(folders[0].selected, true);
  assert.equal((await gateway.interact(BV1, { type: 'favorite', folderIds: [20] })).favorited, true);
  const writes = calls.filter(call => call.options.method === 'POST'); assert.equal(writes.length, 1);
  assert.deepEqual(writes[0].options.form, { rid: 42, type: 2, add_media_ids: '20', del_media_ids: '10', csrf: 'fixture-csrf' });
  await gateway.interact(BV1, { type: 'favorite', folderIds: [20] });
  await assert.rejects(gateway.interact(BV1, { type: 'favorite', folderIds: [99] }), { code: 'INVALID_FOLDER' });
  assert.equal(calls.filter(call => call.options.method === 'POST').length, 1);
});

test('individual writes do not retry a lost response or invent success, and refuse changed sessions', async () => {
  let coins = 0;
  const lost = fixture(({ options }) => { if (options.method === 'POST') { coins = 2; throw new BiliError('UPSTREAM_UNAVAILABLE', 'lost'); } return { like: false, coin: coins, favorite: false }; });
  lost.gateway.video = async () => ({ aid: 42, interaction: { coinLimit: 2 } } as never);
  await loginFixture(lost.transport); await assert.rejects(lost.gateway.interact(BV1, { type: 'coin', coins: 2 }), { code: 'UPSTREAM_UNAVAILABLE' });
  await lost.gateway.interact(BV1, { type: 'coin', coins: 2 }); assert.equal(lost.calls.filter(call => call.options.method === 'POST').length, 1);
  const stale = fixture(() => ({ like: false, coin: 0, favorite: false })); await loginFixture(stale.transport);
  await assert.rejects(stale.gateway.interact(BV1, { type: 'like', liked: true }), { code: 'INTERACTION_UNCONFIRMED' });
  const changed = fixture(() => { changed.transport.jar = new CookieJar(); return { like: false, coin: 0, favorite: false }; }); await loginFixture(changed.transport);
  await assert.rejects(changed.gateway.interact(BV1, { type: 'coin', coins: 1 }), { code: 'LOGIN_REQUIRED' }); assert.ok(changed.calls.every(call => call.options.method !== 'POST'));
  const foreign = fixture(() => ({ count: 1, list: [{ id: 10, mid: 999, fav_state: 0 }] })); foreign.gateway.video = async () => ({ aid: 42 } as never); await loginFixture(foreign.transport);
  await assert.rejects(foreign.gateway.favoriteFolders(BV1), { code: 'FOLDERS_UNAVAILABLE' });
});

test('coin policy follows the actual copyright limit and forwards the simultaneous-like choice', async () => {
  const state = { like: false, coin: 0, favorite: false };
  const { gateway, transport, calls } = fixture(({ options }) => {
    if (options.method === 'POST') { state.coin += Number(options.form?.multiply); state.like ||= options.form?.select_like === 1; return { like: state.like }; }
    return { ...state };
  });
  gateway.video = async () => ({ aid: 42, interaction: { coinLimit: 1 } } as never); await loginFixture(transport);
  await assert.rejects(gateway.interact(BV1, { type: 'coin', coins: 2, selectLike: true }), { code: 'COIN_LIMIT' });
  assert.equal(calls.filter(call => call.options.method === 'POST').length, 0);
  assert.deepEqual(await gateway.interact(BV1, { type: 'coin', coins: 1, selectLike: true }), { liked: true, coins: 1, favorited: false });
  assert.equal(calls.find(call => call.options.method === 'POST')?.options.form?.select_like, 1);
  await assert.rejects(gateway.interact(BV1, { type: 'coin', coins: 1, selectLike: 'yes' } as never), { code: 'INVALID_INPUT' });
  for (const copyright of [1, 2, 3]) {
    const video = fixture(() => ({ aid: 42, copyright, stat: { like: 10, coin: 20, favorite: 30 } }));
    assert.deepEqual((await video.gateway.video(BV1)).interaction, { coinLimit: copyright === 2 ? 1 : 2, likes: 10, coins: 20, favorites: 30 });
  }
});

test('a delayed readback retries only reads and confirms the eventual state without another write', async () => {
  let written = false, readsAfterWrite = 0;
  const { gateway, transport, calls } = fixture(({ options }) => {
    if (options.method === 'POST') { written = true; return null; }
    return { like: written && ++readsAfterWrite >= 2, coin: 0, favorite: false };
  });
  await loginFixture(transport);
  assert.equal((await gateway.interact(BV1, { type: 'like', liked: true })).liked, true);
  assert.equal(calls.filter(call => call.options.method === 'POST').length, 1); assert.equal(readsAfterWrite, 2);
});

test('coin information and optional experience use real account data without any write', async () => {
  let experience = 40;
  const { gateway, transport, calls } = fixture(({ url }) => url.endsWith('/exp') ? experience : { like: true, coin: 1, favorite: false });
  gateway.video = async () => ({ interaction: { coinLimit: 2 } } as never); await loginFixture(transport);
  assert.deepEqual(await gateway.coinInfo(BV1), { coinLimit: 2, state: { liked: true, coins: 1, favorited: false } });
  assert.equal(await gateway.coinExperience(), 40); experience = 99;
  await assert.rejects(gateway.coinExperience(), { code: 'COIN_INFO_UNAVAILABLE' }); assert.ok(calls.every(call => call.options.method !== 'POST'));
});

test('favorite folders preserve privacy and limits and list already-selected folders first', async () => {
  const { gateway, transport } = fixture(() => ({ count: 3, list: [{ id: 10, mid: 7, attr: 1, fav_state: 0, media_count: 50 }, { id: 20, mid: 7, attr: 2, fav_state: 1, media_count: 10 }, { id: 30, mid: 7, attr: 2, fav_state: 0, max_count: 2000, media_count: 4 }] }));
  gateway.video = async () => ({ aid: 42 } as never); await loginFixture(transport);
  const list = await gateway.favoriteFolders(BV1);
  assert.deepEqual(list.map(folder => folder.id), [20, 10, 30]); assert.equal(list[1].isPrivate, true); assert.equal(list[1].isDefault, true); assert.equal(list[1].capacity, 50_000); assert.equal(list[0].capacity, 1000); assert.equal(list[2].capacity, 2000);
});

test('creating a folder is explicitly public, merges concurrent requests and does not favorite the video', async () => {
  let created = false;
  const { gateway, transport, calls } = fixture(({ url, options }) => {
    if (url.endsWith('/folder/add')) { created = true; assert.deepEqual(options.form, { title: 'Study', privacy: 0, csrf: 'fixture-csrf' }); return { id: 22 }; }
    return { count: created ? 1 : 0, list: created ? [{ id: 22, mid: 7, attr: 2, title: 'Study', fav_state: 0, media_count: 0 }] : [] };
  });
  gateway.video = async () => ({ aid: 42 } as never); await loginFixture(transport);
  const [first, second] = await Promise.all([gateway.createFavoriteFolder(BV1, 'Study'), gateway.createFavoriteFolder(BV1, 'Study')]);
  assert.deepEqual(first, second); assert.equal(first.selected, false); assert.equal(calls.filter(call => call.options.method === 'POST').length, 1);
  assert.ok(calls.every(call => !call.url.includes('/resource/deal')));
  await assert.rejects(gateway.createFavoriteFolder(BV1, ''), { code: 'INVALID_FOLDER_NAME' });
  await assert.rejects(gateway.createFavoriteFolder(BV1, 'x'.repeat(21)), { code: 'INVALID_FOLDER_NAME' });
});

test('full folders cannot receive new videos, but a previously saved video can be removed', async () => {
  let selected = false;
  const { gateway, transport, calls } = fixture(({ url, options }) => {
    if (url.endsWith('/list-all')) return { count: 1, list: [{ id: 10, mid: 7, attr: 2, fav_state: selected ? 1 : 0, media_count: 1000 }] };
    if (options.method === 'POST') { selected = false; return {}; }
    return { like: false, coin: 0, favorite: selected };
  });
  gateway.video = async () => ({ aid: 42 } as never); await loginFixture(transport);
  await assert.rejects(gateway.interact(BV1, { type: 'favorite', folderIds: [10] }), { code: 'FOLDER_FULL' }); assert.equal(calls.filter(call => call.options.method === 'POST').length, 0);
  selected = true; assert.equal((await gateway.interact(BV1, { type: 'favorite', folderIds: [] })).favorited, false);
  assert.equal(calls.filter(call => call.options.method === 'POST').length, 1);
});

test('engagement reads all three real states with one relation request and rejects incomplete data', async () => {
  const { gateway, calls } = fixture(() => ({ like: true, coin: 1, favorite: false }));
  assert.deepEqual(await gateway.engagement(BV1), { liked: true, coins: 1, favorited: false });
  assert.equal(calls.length, 1); assert.match(calls[0].url, /archive\/relation$/); assert.deepEqual(calls[0].options.query, { bvid: BV1 });
  await assert.rejects(fixture(() => ({ like: true })).gateway.engagement(BV1), { code: 'INVALID_RESPONSE' });
});

test('concurrent triple clicks share one upstream write, keep CSRF server-side, then confirm actual states', async () => {
  const gate = deferred<void>(); let written = false;
  const { gateway, transport, calls } = fixture(async ({ url }) => {
    if (url.endsWith('/triple')) { await gate.promise; written = true; return { like: true, coin: true, fav: true, multiply: 2 }; }
    return { like: written, coin: written ? 2 : 0, favorite: written };
  });
  await loginFixture(transport);
  const a = gateway.triple(BV1), b = gateway.triple(BV1); gate.resolve();
  const [left, right] = await Promise.all([a, b]); assert.deepEqual(left, right); assert.equal(left.complete, true);
  const writes = calls.filter(call => call.url.endsWith('/triple')); assert.equal(writes.length, 1);
  assert.deepEqual(writes[0].options.form, { bvid: BV1, csrf: 'fixture-csrf' }); assert.equal(writes[0].options.method, 'POST');
  assert.equal(writes[0].options.headers?.origin, 'https://www.bilibili.com'); assert.ok(!JSON.stringify(left).includes('fixture-'));
  await gateway.triple(BV1); assert.equal(calls.filter(call => call.url.endsWith('/triple')).length, 1);
});

test('a partial triple is never reported complete and a lost response is not automatically resubmitted', async () => {
  let applied = false; const { gateway, transport, calls } = fixture(({ url }) => {
    if (url.endsWith('/triple')) { applied = true; return { like: true, coin: false, fav: true, multiply: 0 }; }
    return { like: applied, coin: 0, favorite: applied };
  });
  await loginFixture(transport); const result = await gateway.triple(BV1); assert.equal(result.complete, false); assert.equal(result.state.coins, 0);
  let completed = false;
  const lost = fixture(({ url }) => { if (url.endsWith('/triple')) { completed = true; throw new BiliError('UPSTREAM_UNAVAILABLE', 'response lost'); } return { like: completed, coin: completed ? 2 : 0, favorite: completed }; });
  await loginFixture(lost.transport); await assert.rejects(lost.gateway.triple(BV1), { code: 'UPSTREAM_UNAVAILABLE' });
  assert.equal(lost.calls.filter(call => call.url.endsWith('/triple')).length, 1);
  assert.equal((await lost.gateway.triple(BV1)).complete, true); assert.equal(lost.calls.filter(call => call.url.endsWith('/triple')).length, 1);
  assert.equal(calls.filter(call => call.url.endsWith('/triple')).length, 1);
});

test('triple refuses missing credentials, malformed results and account changes before a write', async () => {
  const anonymous = fixture(() => ({})); await assert.rejects(anonymous.gateway.triple(BV1), { code: 'LOGIN_REQUIRED' }); assert.equal(anonymous.calls.length, 0);
  const changed = fixture(() => { changed.transport.jar = new CookieJar(); return { like: false, coin: 0, favorite: false }; });
  await loginFixture(changed.transport); await assert.rejects(changed.gateway.triple(BV1), { code: 'LOGIN_REQUIRED' }); assert.equal(changed.calls.length, 1);
  const malformed = fixture(({ url }) => url.endsWith('/triple') ? {} : { like: false, coin: 0, favorite: false });
  await loginFixture(malformed.transport); await assert.rejects(malformed.gateway.triple(BV1), { code: 'TRIPLE_UNCONFIRMED' });
  let written = false;
  const expired = fixture(({ options }) => { if (options.method === 'POST') { written = true; return { like: true, coin: true, fav: true }; } if (written) throw new BiliError(-101, '登录已失效', 401); return { like: false, coin: 0, favorite: false }; });
  await loginFixture(expired.transport); await assert.rejects(expired.gateway.triple(BV1), { code: '-101', status: 401 });
});

test('search uses only the explicit query and maps sanitized results with upstream pagination', async () => {
  const { gateway, calls } = fixture(() => ({ result: [{ bvid: BV1, aid: 1, title: '<em>物理</em> &amp; &lt;img src=x&gt;实验', pic: '//i0.hdslb.com/cover.jpg', mid: 7, author: '<b>Teacher</b>', duration: '1:02:03', pubdate: 20, play: '1.2万' }], numPages: 3 }));
  const result = await gateway.search('物理', 'video', 2);
  assert.equal(result.videos[0].title, '物理 & 实验');
  assert.equal(result.videos[0].duration, 3723); assert.equal(result.videos[0].views, 12000);
  assert.equal(result.videos[0].cover, 'https://i0.hdslb.com/cover.jpg'); assert.equal(result.hasMore, true);
  assert.equal(calls.length, 1); assert.match(calls[0].url, /\/wbi\/search\/type$/);
  assert.deepEqual(calls[0].options.query, { keyword: '物理', search_type: 'video', page: 2, page_size: 30, order: 'totalrank' });
  assert.equal(calls[0].options.wbi, true);
});

test('creator search maps users and rejects blank or invalid page input', async () => {
  const { gateway } = fixture(() => ({ result: [{ mid: 2, uname: '<em>Teacher</em>', upic: '//i0.hdslb.com/face.jpg', usign: '<b>Science</b>', fans: 12 }], numPages: 1 }));
  const result = await gateway.search('Teacher', 'user', 1);
  assert.equal(result.users[0].name, 'Teacher'); assert.equal(result.users[0].description, 'Science'); assert.equal(result.hasMore, false);
  await assert.rejects(gateway.search('  ', 'video', 1), { code: 'INVALID_INPUT' });
  await assert.rejects(gateway.search('x', 'video', -1), { code: 'INVALID_INPUT' });
});

test('following filters injected recommendations, reposts and owner mismatches then sorts and deduplicates', async () => {
  const wrongOwner = post(BV3, 7, 90); (wrongOwner.modules.module_dynamic.major.archive as Record<string, unknown>).owner = { mid: 999 };
  const { gateway, calls } = fixture(({ url }) => {
    if (url.endsWith('/nav')) return { isLogin: true, mid: 1 };
    if (url.endsWith('/followings')) return { total: 1, list: [{ mid: 7 }] };
    return { items: [post(BV1, 7, 10), post(BV2, 7, 20), post(BV3, 999, 100), post(BV1, 7, 10), post(BV3, 7, 200, { type: 'DYNAMIC_TYPE_FORWARD', orig: {} }), wrongOwner], offset: 'next-page', has_more: true };
  });
  const result = await gateway.following();
  assert.deepEqual(result.items.map(item => item.bvid), [BV2, BV1]);
  assert.equal(result.items[0].duration, 85); assert.equal(result.items[0].owner.mid, 7);
  assert.equal(result.nextCursor, 'next-page'); assert.equal(result.hasMore, true);
  assert.deepEqual(calls.find(call => call.url.endsWith('/feed/all'))?.options.query, { type: 'video' });
  assert.ok(calls.every(call => !/rcmd|popular|ranking|feed\/index|\/space\//.test(call.url)));
});

test('following enumerates all follow pages before applying cursor and cannot use stale account cache', async () => {
  let account = 1;
  const { gateway, calls } = fixture(({ url, options }) => {
    if (url.endsWith('/nav')) return { isLogin: true, mid: account };
    if (url.endsWith('/followings')) {
      if (account === 2) return { total: 1, list: [{ mid: 8 }] };
      return { total: 51, list: options.query?.pn === 1 ? Array.from({ length: 50 }, (_, i) => ({ mid: i + 100 })) : [{ mid: 7 }] };
    }
    return { items: [post(BV1, 7, 5), post(BV2, 8, 10)], offset: 'done', has_more: 0 };
  });
  assert.deepEqual((await gateway.following('page-2')).items.map(item => item.bvid), [BV1]);
  assert.deepEqual(calls.filter(call => call.url.endsWith('/followings')).map(call => call.options.query?.pn), [1, 2]);
  assert.equal(calls.find(call => call.url.endsWith('/feed/all'))?.options.query?.offset, 'page-2');
  account = 2; assert.deepEqual((await gateway.following()).items.map(item => item.bvid), [BV2]);
});

test('following requires login, keeps filtered-empty pages navigable and stops repeated cursor', async () => {
  const anon = fixture(() => ({ isLogin: false }));
  await assert.rejects(anon.gateway.following(), { code: 'LOGIN_REQUIRED', status: 401 }); assert.equal(anon.calls.length, 1);
  const { gateway } = fixture(({ url }) => url.endsWith('/nav') ? { isLogin: true, mid: 1 } : url.endsWith('/followings') ? { total: 1, list: [{ mid: 7 }] } : { items: [post(BV1, 999, 4)], offset: 'next', has_more: 1 });
  assert.deepEqual(await gateway.following(), { items: [], hasMore: true, nextCursor: 'next' });
  assert.deepEqual(await gateway.following('next'), { items: [], hasMore: false });
});

test('following keeps deduplication local to a page so independent browser sessions cannot consume each other’s results', async () => {
  const { gateway } = fixture(({ url, options }) => url.endsWith('/nav') ? { isLogin: true, mid: 1 } : url.endsWith('/followings') ? { total: 1, list: [{ mid: 7 }] } : { items: [post(BV1, 7, 10)], offset: options.query?.offset ? 'page-3' : 'page-2', has_more: 1 });
  const first = await gateway.following(), second = await gateway.following(first.nextCursor);
  // The UI merges accumulated pages by bvid; server-side global consumption would break another open tab.
  assert.equal(first.items[0].bvid, BV1); assert.equal(second.items[0].bvid, BV1);
});

test('following starts the feed while the complete follow list is pending and shares one concurrent enumeration', async () => {
  const listStarted = deferred<void>(), releaseList = deferred<void>(), feedsStarted = deferred<void>();
  let feedCount = 0;
  const { gateway, calls } = fixture(async ({ url, options }) => {
    if (url.endsWith('/nav')) return { isLogin: true, mid: 1 };
    if (url.endsWith('/followings')) {
      if (options.query?.pn === 1) {
        listStarted.resolve(); await releaseList.promise;
        return { total: 51, list: Array.from({ length: 50 }, (_, i) => ({ mid: i + 100 })) };
      }
      return { total: 51, list: [{ mid: 7 }] };
    }
    if (++feedCount === 2) feedsStarted.resolve();
    return { items: [post(BV1, 7, 10), post(BV2, 999, 20)], offset: 'done', has_more: 0 };
  });
  let settled = false;
  const requests = Promise.all([gateway.following(), gateway.following('page-2')]).then(results => { settled = true; return results; });
  await listStarted.promise;
  try {
    // Both feed requests must start before releasing the first follow-list page.
    assert.equal(feedCount, 2);
    await feedsStarted.promise;
    assert.deepEqual(calls.filter(call => call.url.endsWith('/followings')).map(call => call.options.query?.pn), [1]);
    assert.equal(settled, false);
  } finally { releaseList.resolve(); }
  const results = await requests;
  assert.deepEqual(results.map(result => result.items.map(item => item.bvid)), [[BV1], [BV1]]);
  assert.deepEqual(calls.filter(call => call.url.endsWith('/followings')).map(call => call.options.query?.pn), [1, 2]);
});

test('following retries a failed shared follow-list build rather than caching incomplete account data', async () => {
  const listStarted = deferred<void>(), releaseList = deferred<void>();
  let fail = true;
  const { gateway, calls } = fixture(async ({ url }) => {
    if (url.endsWith('/nav')) return { isLogin: true, mid: 1 };
    if (url.endsWith('/followings')) {
      if (fail) { listStarted.resolve(); await releaseList.promise; throw new BiliError('FOLLOW_UPSTREAM_FAILED', '关注列表暂不可用', 502); }
      return { total: 1, list: [{ mid: 7 }] };
    }
    return { items: [post(BV1, 7, 10)], has_more: 0 };
  });
  const requests = Promise.allSettled([gateway.following(), gateway.following('page-2')]);
  await listStarted.promise; releaseList.resolve();
  for (const result of await requests) {
    assert.equal(result.status, 'rejected');
    if (result.status === 'rejected') assert.equal(result.reason.code, 'FOLLOW_UPSTREAM_FAILED');
  }
  assert.equal(calls.filter(call => call.url.endsWith('/followings')).length, 1);
  fail = false;
  assert.equal((await gateway.following()).items[0].bvid, BV1);
  assert.equal(calls.filter(call => call.url.endsWith('/followings')).length, 2);
});

test('cold following verification reads remaining follow pages with at most three concurrent requests', async () => {
  const started = deferred<void>(), release = deferred<void>();
  const pages: number[] = []; let active = 0, maximum = 0;
  const { gateway } = fixture(async ({ url, options }) => {
    if (url.endsWith('/nav')) return { isLogin: true, mid: 1 };
    if (!url.endsWith('/followings')) return { items: [post(BV1, 7, 10), post(BV2, 999, 20)], has_more: 0 };
    const pn = Number(options.query?.pn); pages.push(pn);
    if (pn > 1 && pn < 5) { active++; maximum = Math.max(maximum, active); started.resolve(); await release.promise; active--; }
    return { total: 201, list: pn === 5 ? [{ mid: 7 }] : Array.from({ length: 50 }, (_, i) => ({ mid: pn * 100 + i })) };
  });
  const request = gateway.following();
  await started.promise;
  try { assert.deepEqual([...pages], [1, 2, 3, 4], 'the first blocked page must not serialize all later verification'); }
  finally { release.resolve(); }
  assert.deepEqual((await request).items.map(item => item.bvid), [BV1], 'even the final follow-list page must be checked before rendering');
  assert.equal(maximum, 3);
  assert.deepEqual(pages, [1, 2, 3, 4, 5]);
});

test('replacing the session jar cannot reuse or overwrite a newer follow-list build for the same account', async () => {
  const started = deferred<void>(), release = deferred<void>(); let builds = 0;
  const { gateway, transport } = fixture(async ({ url }) => {
    if (url.endsWith('/nav')) return { isLogin: true, mid: 1 };
    if (url.endsWith('/followings')) {
      if (++builds === 1) { started.resolve(); await release.promise; return { total: 1, list: [{ mid: 7 }] }; }
      return { total: 1, list: [{ mid: 8 }] };
    }
    return { items: [post(BV1, 7, 10), post(BV2, 8, 20)], has_more: 0 };
  });
  const old = gateway.following(); await started.promise;
  transport.jar = new CookieJar();
  try { assert.deepEqual((await gateway.following()).items.map(item => item.bvid), [BV2]); }
  finally { release.resolve(); }
  await old;
  assert.deepEqual((await gateway.following()).items.map(item => item.bvid), [BV2]);
  assert.equal(builds, 2, 'the older completion must not replace the new session cache');
});

test('creator videos preserve owner, chronological order and numeric pagination', async () => {
  const { gateway } = fixture(({ url }) => url.endsWith('/acc/info') ? { mid: 7, name: 'Teacher', sign: '<b>Science</b>', face: '//i0.hdslb.com/a.jpg' } : { list: { vlist: [{ bvid: BV1, aid: 1, title: 'older', created: 10 }, { bvid: BV2, aid: 2, title: 'newer', created: 20 }] }, page: { count: 61 } });
  const result = await gateway.creatorVideos(7, 2);
  assert.deepEqual(result.items.map(item => item.bvid), [BV2, BV1]); assert.equal(result.items[0].owner.name, 'Teacher'); assert.equal(result.nextPage, 3);
});

test('creator video limits distinguish upstream risk controls from confirmed login requirements', async () => {
  for (const code of [412, -352]) {
    const { gateway } = fixture(({ url }) => url.endsWith('/acc/info') ? { mid: 7, name: 'Teacher' } : Promise.reject(new BiliError(code, 'Upstream limited')));
    await assert.rejects(gateway.creatorVideos(7), { code: 'RISK_CONTROL', status: 429 });
  }
  const { gateway } = fixture(({ url }) => url.endsWith('/acc/info') ? { mid: 7, name: 'Teacher' } : Promise.reject(new BiliError(-101, 'Logged out')));
  await assert.rejects(gateway.creatorVideos(7), { code: 'LOGIN_REQUIRED', status: 401 });
});

test('video details map real parts and reject invalid BV ids before a request', async () => {
  const { gateway, calls } = fixture(() => ({ aid: 1, title: '<b>Title</b>', desc: '<script>bad()</script>Description', owner: { mid: 7, name: 'Teacher' }, pages: [{ cid: 5, page: 1, part: 'Part', duration: 60 }], stat: { view: 42 } }));
  const result = await gateway.video(BV1); assert.equal(result.description, 'Description'); assert.equal(result.parts[0].cid, 5);
  assert.match(calls[0].url, /\/web-interface\/wbi\/view$/); assert.equal(calls[0].options.wbi, true);
  await assert.rejects(gateway.video('../private'), { code: 'INVALID_INPUT' }); assert.equal(calls.length, 1);
});

test('video detail readers share one pending request and reuse only a short bounded session cache', async t => {
  t.mock.timers.enable({ apis: ['Date'], now: 1000 });
  const release = deferred<void>();
  const { gateway, calls } = fixture(async () => { await release.promise; return { aid: 1, pages: [{ cid: 5 }] }; });
  const readers = [gateway.video(BV1), gateway.video(BV1), gateway.video(BV1)];
  assert.equal(calls.length, 1);
  release.resolve(); await Promise.all(readers);
  await gateway.video(BV1); assert.equal(calls.length, 1);
  t.mock.timers.tick(30_001);
  await gateway.video(BV1); assert.equal(calls.length, 2);
  for (let id = 2; id <= 65; id++) await gateway.video(`BV${String(id).padStart(10, '0')}`);
  await gateway.video(BV1); assert.equal(calls.length, 67);
});

test('failed video detail requests are shared while pending but retried rather than cached', async () => {
  const release = deferred<void>(); let failed = true;
  const { gateway, calls } = fixture(async () => {
    if (failed) { await release.promise; throw new BiliError('UPSTREAM_FAILED', '详情暂不可用', 502); }
    return { aid: 1, pages: [{ cid: 5 }] };
  });
  const readers = Promise.allSettled([gateway.video(BV1), gateway.video(BV1)]);
  assert.equal(calls.length, 1); release.resolve();
  assert.ok((await readers).every(result => result.status === 'rejected'));
  failed = false; assert.equal((await gateway.video(BV1)).aid, 1); assert.equal(calls.length, 2);
});

test('replacing the session jar invalidates cached and pending details, including late old-session responses', async () => {
  const release = deferred<void>(); let started = 0;
  const { gateway, transport, calls } = fixture(async () => {
    const aid = ++started;
    if (aid === 1) await release.promise;
    return { aid, pages: [{ cid: aid }] };
  });
  const oldSession = gateway.video(BV1);
  transport.jar = new CookieJar();
  const newSession = gateway.video(BV1);
  try { assert.equal(calls.length, 2); assert.equal((await newSession).aid, 2); }
  finally { release.resolve(); }
  assert.equal((await oldSession).aid, 1);
  assert.equal((await gateway.video(BV1)).aid, 2); assert.equal(calls.length, 2);
  transport.jar = new CookieJar();
  assert.equal((await gateway.video(BV1)).aid, 3); assert.equal(calls.length, 3);
});

test('playback starts subtitles alongside playurl and defaults to the highest offered AVC quality', async () => {
  const release = deferred<void>();
  const { gateway, calls } = fixture(async ({ url }) => {
    if (!url.endsWith('/playurl')) return {};
    await release.promise;
    return { dash: { video: [track(80, 'avc1.640032'), track(120, 'avc1.640033'), track(127, 'hev1.1.6.L153.90')], audio: [track(30280, 'mp4a.40.2')] } };
  });
  const pending = gateway.playback(BV1, 5);
  try {
    assert.deepEqual(calls.map(call => call.url.split('/').pop()), ['playurl', 'v2']);
    assert.equal(calls[0].options.query?.qn, 127);
  } finally { release.resolve(); }
  const result = await pending;
  assert.equal(result.quality, 120); assert.deepEqual(result.qualities.map(item => item.id), [120, 80]);
  assert.equal((await gateway.playback(BV1, 5, 80)).quality, 80);
  assert.equal(calls.filter(call => call.url.endsWith('/playurl')).at(-1)?.options.query?.qn, 80);
});

test('playback selects AVC and AAC, keeps byte ranges and derives only offered AVC qualities', async () => {
  const { gateway } = fixture(({ url }) => url.endsWith('/playurl') ? { dash: { duration: 61, video: [track(80, 'hev1.1.6.L120.90'), track(64, 'avc1.640028'), track(80, 'avc1.640032')], audio: [track(30280, 'mp4a.40.2'), track(30251, 'fLaC', 9000)] }, accept_quality: [80, 64], accept_description: ['1080P', '720P'] } : { subtitle: { subtitles: [{ id: 4, lan: 'zh-CN', lan_doc: '中文', subtitle_url: '//aisubtitle.hdslb.com/file.json' }] } });
  const result = await gateway.playback(BV1, 5, 80);
  assert.equal(result.video?.codecs, 'avc1.640032'); assert.equal(result.audio?.codecs, 'mp4a.40.2');
  assert.equal(result.duration, 61); assert.deepEqual(result.video?.segmentBase, { initialization: '0-999', indexRange: '1000-2000' });
  assert.deepEqual(result.qualities, [{ id: 80, label: '1080P' }, { id: 64, label: '720P' }]);
  assert.equal(result.subtitles[0].url, 'https://aisubtitle.hdslb.com/file.json'); assert.equal(result.segments, undefined);
});

test('playback refuses HEVC-only or FLV media and does not invent a progressive MP4', async () => {
  for (const payload of [{ dash: { video: [track(80, 'hev1.1.6.L120.90')], audio: [track(30280, 'mp4a.40.2')] } }, { format: 'flv720', durl: [{ url: 'https://upos.bilivideo.com/video.flv', length: 1000 }] }]) {
    const { gateway } = fixture(({ url }) => url.endsWith('/playurl') ? payload : {});
    await assert.rejects(gateway.playback(BV1, 5), { code: 'UNSUPPORTED_PLAYBACK', status: 422 });
  }
  const { gateway } = fixture(({ url }) => url.endsWith('/playurl') ? { format: 'mp4', quality: 64, timelength: 1000, durl: [{ url: 'https://upos.bilivideo.com/video.mp4', length: 1000 }] } : Promise.reject(new BiliError(-101, 'No subtitle', 401)));
  const result = await gateway.playback(BV1, 5); assert.equal(result.segments?.[0].length, 1000); assert.deepEqual(result.subtitles, []);
});

test('playback supports real silent video-only DASH and does not invent an audio track', async () => {
  const { gateway } = fixture(({ url }) => url.endsWith('/playurl') ? { dash: { duration: 5, video: [track(80, 'avc1.640032')], audio: [] } } : {});
  const result = await gateway.playback(BV1, 5);
  assert.equal(result.video?.id, 80); assert.equal(result.audio, undefined); assert.equal(result.duration, 5);
});

test('danmaku parses real XML attributes, decodes safe text and drops unsupported modes', async () => {
  const { gateway } = fixture(() => { throw new Error('Unexpected API'); }, () => new Response('<i><d p="1.5,1,25,16777215,1,0,u,1">Hello &amp; world</d><d p="2,7,25,255,1,0,u,2">Advanced</d></i>'));
  assert.deepEqual(await gateway.danmaku(5), [{ text: 'Hello & world', time: 1.5, mode: 1, fontSize: 25, color: '#ffffff' }]);
});

test('comments include only the requested page and initial child replies with sanitized text', async () => {
  const { gateway, calls } = fixture(() => ({ cursor: { is_end: false, all_count: 41, pagination_reply: { next_offset: '{"type":3,"cursor":123}' } }, replies: [{ rpid_str: '1', member: { mid: 7, uname: '<b>Teacher</b>' }, content: { message: '<script>x()</script>Hello' }, ctime: 3, like: 4, replies: [{ rpid: 2, member: { mid: 8, uname: 'Student' }, content: { message: 'Child' } }] }] }));
  const result = await gateway.comments(9, 2, 'opaque-next');
  assert.equal(result.items[0].text, 'Hello'); assert.equal(result.items[0].user.name, 'Teacher'); assert.equal(result.items[0].replies[0].text, 'Child'); assert.equal(result.nextPage, 3);
  assert.equal(result.nextCursor, '{"type":3,"cursor":123}');
  assert.deepEqual(calls[0].options.query, { type: 1, oid: 9, mode: 2, pagination_str: '{"offset":"opaque-next"}', plat: 1, web_location: '1315875' });
  assert.equal(calls[0].options.wbi, true); assert.match(calls[0].url, /\/reply\/wbi\/main$/);
});

test('comments accept a real empty terminal page but reject fake empty or incomplete upstream data', async () => {
  const terminal = fixture(() => ({ cursor: { is_end: true, all_count: 0 }, replies: [] }));
  assert.deepEqual(await terminal.gateway.comments(9), { items: [], hasMore: false });
  for (const payload of [{ page: { count: 0, size: 0 }, replies: null }, { cursor: { is_end: false, all_count: 100 }, replies: [] }, { cursor: { is_end: false }, replies: [{ rpid: 1 }] }]) {
    const broken = fixture(() => payload); await assert.rejects(broken.gateway.comments(9), { code: 'COMMENTS_UNAVAILABLE' });
  }
  await assert.rejects(terminal.gateway.comments(9, 2), { code: 'INVALID_INPUT' });
});

test('comments preserve opaque repeated offsets because upstream may keep them stable between distinct pages', async () => {
  let page = 0;
  const { gateway } = fixture(() => ({ cursor: { is_end: false, pagination_reply: { next_offset: 'opaque-stable' } }, replies: [{ rpid: ++page, content: { message: 'Comment' } }] }));
  const first = await gateway.comments(9), second = await gateway.comments(9, 2, first.nextCursor);
  assert.equal(second.hasMore, true); assert.notEqual(first.items[0].id, second.items[0].id); assert.equal(first.nextCursor, second.nextCursor);
});

test('resolve accepts keywords, BV, av and canonical creator/search links', async () => {
  const { gateway } = fixture(() => ({ bvid: BV1 }));
  assert.equal(await gateway.resolve(BV1), `/video/${BV1}`); assert.equal(await gateway.resolve('av170001'), `/video/${BV1}`);
  assert.equal(await gateway.resolve(`https://www.bilibili.com/video/${BV2}?spm_id_from=1`), `/video/${BV2}`);
  assert.equal(await gateway.resolve(`https://www.bilibili.com/video/${BV2}?p=3`), `/video/${BV2}?p=3`);
  assert.equal(await gateway.resolve('https://space.bilibili.com/123'), '/creator/123');
  assert.equal(await gateway.resolve('量子物理'), '/search?keyword=%E9%87%8F%E5%AD%90%E7%89%A9%E7%90%86&type=video&page=1');
  assert.equal(await gateway.resolve('https://search.bilibili.com/all?keyword=test'), '/search?keyword=test&type=video&page=1');
  assert.equal(await gateway.resolve('https://www.bilibili.com/'), '/');
  assert.equal(await gateway.resolve('https://www.bilibili.com/?spm_id_from=333.1007.0.0'), '/');
  assert.equal(await gateway.resolve('https://bilibili.com'), '/');
});

test('resolve follows only manual Bili short-link redirects and blocks unsafe protocols, hosts and ports', async () => {
  const { gateway, fetches } = fixture(() => ({}), () => new Response(null, { status: 302, headers: { location: `https://www.bilibili.com/video/${BV1}` } }));
  assert.equal(await gateway.resolve('https://b23.tv/safe'), `/video/${BV1}`); assert.equal(fetches[0].init?.redirect, 'manual');
  for (const input of ['http://b23.tv/a', 'https://127.0.0.1/', 'https://bilibili.com.attacker.test/', 'https://www.bilibili.com:8443/', 'https://user:pass@b23.tv/x', 'file:///etc/passwd', 'javascript:alert(1)']) await assert.rejects(gateway.resolve(input), { code: 'UNSAFE_URL' });
  const unsafe = fixture(() => ({}), () => new Response(null, { status: 302, headers: { location: 'http://169.254.169.254/latest/meta-data/' } }));
  await assert.rejects(unsafe.gateway.resolve('https://b23.tv/unsafe'), { code: 'UNSAFE_URL' }); assert.equal(unsafe.fetches.length, 1);
});
