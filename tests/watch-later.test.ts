import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createApp } from '../server/app.js';
import type { AuthService } from '../server/auth.js';
import { BiliGateway } from '../server/gateway.js';
import { BiliHttp } from '../server/transport.js';

const mid = 7;
const api = 'https://api.bilibili.com';
const item = (aid: number) => ({
  aid, bvid: 'BV' + String(aid).padStart(10, '0'), title: 'Watch later',
  pic: '//i0.hdslb.com/cover.jpg', owner: { mid: 8, name: 'UP', face: '//i0.hdslb.com/avatar.jpg' },
  cid: 42, duration: 90, progress: -1, add_at: 150,
});

async function watchLaterFixture(initial: number[], pendingRead?: () => Promise<void>) {
  const calls: URL[] = [];
  const posts: { action: string; form: Record<string, string> }[] = [];
  let aids = [...initial];
  let loseResponse = false;
  const transport = new BiliHttp({ fetch: async (input, init) => {
    const url = new URL(String(input));
    const action = url.pathname.split('/').at(-1)!;
    calls.push(url);
    if (action === 'web') {
      const page = Number(url.searchParams.get('pn'));
      const size = Number(url.searchParams.get('ps'));
      assert.equal(url.searchParams.get('asc'), '0');
      assert.equal(url.searchParams.get('need_split'), '1');
      const values = aids.slice((page - 1) * size, page * size).map(aid => aid === 2 ? { ...item(aid), bvid: '' } : item(aid));
      if (pendingRead) await pendingRead();
      return Response.json({ code: 0, data: { count: aids.length, list: page === 1 && values.length ? [{ aid: -1 }, ...values] : values } });
    }
    const request = new Request(url, init);
    assert.match(request.headers.get('content-type') ?? '', action === 'dels'
      ? /^multipart\/form-data; boundary=/
      : /^application\/x-www-form-urlencoded/);
    const form = Object.fromEntries([...(await request.formData())].map(([key, value]) => [key, String(value)]));
    assert.equal(request.headers.get('origin'), 'https://www.bilibili.com');
    posts.push({ action, form });
    if (action === 'add') aids.unshift(Number(form.aid));
    if (action === 'del') aids = aids.filter(aid => aid !== Number(form.aid));
    if (action === 'dels') aids = aids.filter(aid => !form.resources.split(',').map(Number).includes(aid));
    if (loseResponse) { loseResponse = false; throw new Error('simulated dropped response'); }
    return Response.json({ code: 0 });
  } });
  for (const cookie of ['SESSDATA=fixture', 'bili_jct=fixture-csrf', 'DedeUserID=7', 'buvid3=fixture-device']) {
    await transport.jar.setCookie(cookie + '; Domain=.bilibili.com; Path=/; Secure', api);
  }
  return { gateway: new BiliGateway(transport), transport, calls, posts, dropWriteResponse: () => { loseResponse = true; } };
}

test('watch later uses every cloud page for shared membership and keeps removable unavailable videos', async () => {
  const initial = Array.from({ length: 21 }, (_, i) => i + 1);
  const { gateway, calls, posts } = await watchLaterFixture(initial);
  const page = await gateway.watchLater(1, mid);
  assert.equal(page.nextPage, 2);
  assert.equal(page.total, 21);
  assert.equal(page.items.length, 20);
  assert.equal(page.items[0].addedAt, 150);
  assert.equal(page.items[0].progress, -1);
  assert.equal(page.items[1].aid, 2);
  assert.equal(page.items[1].unavailable, true);
  assert.deepEqual(await gateway.watchLaterMembership(mid), { aids: initial, accountMid: mid });
  assert.deepEqual(calls.map(url => url.searchParams.get('pn')), ['1', '1', '2']);
  assert.equal(posts.length, 0);
});

test('watch later merges duplicate writes, confirms a lost response with reads, and removes a batch once', async () => {
  const { gateway, posts, dropWriteResponse } = await watchLaterFixture([1, 2]);
  dropWriteResponse();
  const add = { saved: true, accountMid: mid };
  assert.deepEqual(await Promise.all([gateway.setWatchLater(3, true, mid), gateway.setWatchLater(3, true, mid)]), [add, add]);
  assert.deepEqual(await gateway.setWatchLater(3, true, mid), add);
  assert.deepEqual(await gateway.removeWatchLater([3, 2, 2], mid), { removed: [2, 3], accountMid: mid });
  assert.deepEqual(posts, [
    { action: 'add', form: { aid: '3', csrf: 'fixture-csrf' } },
    { action: 'dels', form: { resources: '2,3', csrf: 'fixture-csrf' } },
  ]);
  assert.deepEqual(await gateway.watchLaterMembership(mid), { aids: [1], accountMid: mid });
});

test('late watch later reads from a replaced account are discarded and cannot start the write', async () => {
  let release!: () => void;
  let started!: () => void;
  const held = new Promise<void>(resolve => { release = resolve; });
  const entered = new Promise<void>(resolve => { started = resolve; });
  const { gateway, transport, posts } = await watchLaterFixture([], async () => { started(); await held; });
  const writing = gateway.setWatchLater(3, true, mid);
  await entered;
  await transport.jar.setCookie('DedeUserID=9; Domain=.bilibili.com; Path=/; Secure', api);
  release();
  await assert.rejects(writing, { code: 'ACCOUNT_CHANGED' });
  assert.equal(posts.length, 0);
});

test('watch later routes isolate the account, protect writes and return only proxied images', async t => {
  const { gateway, posts } = await watchLaterFixture([1]);
  let activeMid = mid;
  const auth = { state: async () => ({ authenticated: activeMid > 0, user: activeMid > 0 ? { mid: activeMid, name: 'Reader', avatar: '' } : undefined }) } as AuthService;
  const app = await createApp({ auth, gateway, key: randomBytes(32), staticDir: '/nonexistent' });
  t.after(() => app.close());
  const host = '127.0.0.1:3880';
  const page = await app.inject({ url: '/api/watch-later?accountMid=7', headers: { host } });
  assert.equal(page.statusCode, 200);
  assert.match(page.json().items[0].cover, /^\/api\/media\//);
  assert.ok(!page.body.includes('hdslb.com'));
  const headers = { host, origin: 'http://' + host, 'x-bilight-request': '1', cookie: String(page.headers['set-cookie']).split(';')[0] };
  const payload = { accountMid: mid, saved: false };
  const url = '/api/watch-later/1';
  assert.equal((await app.inject({ method: 'PUT', url, headers: { ...headers, origin: 'https://invalid.example' }, payload })).statusCode, 403);
  assert.equal((await app.inject({ method: 'PUT', url, headers, payload: { ...payload, accountMid: 9 } })).statusCode, 409);
  assert.equal((await app.inject({ method: 'PUT', url, headers, payload })).statusCode, 200);
  assert.deepEqual(posts, [{ action: 'del', form: { aid: '1', csrf: 'fixture-csrf' } }]);
  activeMid = 0;
  assert.equal((await app.inject({ url: '/api/watch-later/membership?accountMid=7', headers })).statusCode, 401);
});
