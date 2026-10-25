import test from 'node:test';
import assert from 'node:assert/strict';
import { CookieJar } from 'tough-cookie';
import { BiliHttp } from '../server/transport.js';

test('normal device identifiers come from the official SPI endpoint once and persist server-side', async () => {
  let calls = 0, persisted = 0;
  const http = new BiliHttp({ fetch: (async value => {
    assert.equal(String(value), 'https://api.bilibili.com/x/frontend/finger/spi'); calls++;
    return Response.json({ code: 0, data: { b_3: 'official-device-id-123', b_4: 'official-device-four==' } });
  }) as typeof fetch });
  http.onCookiesChanged = () => { persisted++; };
  await Promise.all([http.ensureDeviceCookies(), http.ensureDeviceCookies()]);
  await http.ensureDeviceCookies(); assert.equal(calls, 1); assert.equal(persisted, 1);
  const cookies = await http.jar.getCookies('https://api.bilibili.com/');
  assert.equal(cookies.find(cookie => cookie.key === 'buvid3')?.value, 'official-device-id-123');
  assert.equal(cookies.find(cookie => cookie.key === 'buvid4')?.value, 'official-device-four==');
  assert.ok(cookies.every(cookie => cookie.secure && cookie.domain === 'bilibili.com'));
});

test('device setup keeps an existing identifier and refuses malformed official data', async () => {
  const existing = new BiliHttp({ fetch: (async () => { throw new Error('must not replace existing cookie'); }) as typeof fetch });
  await existing.jar.setCookie('buvid3=existing-device; Domain=.bilibili.com; Path=/; Secure', 'https://www.bilibili.com/');
  await existing.ensureDeviceCookies();
  const invalid = new BiliHttp({ fetch: (async () => Response.json({ code: 0, data: { b_3: 'injection; SESSDATA=bad' } })) as typeof fetch });
  await assert.rejects(invalid.ensureDeviceCookies(), { code: 'INVALID_RESPONSE' });
  assert.equal(await invalid.jar.getCookieString('https://api.bilibili.com/'), '');
});

test('a device response after logout cannot populate the new jar or persist old state', async () => {
  let release!: (response: Response) => void, started!: () => void, persisted = 0;
  const ready = new Promise<void>(resolve => { started = resolve; });
  const http = new BiliHttp({ fetch: (() => { started(); return new Promise<Response>(resolve => { release = resolve; }); }) as typeof fetch });
  http.onCookiesChanged = () => { persisted++; };
  const task = http.ensureDeviceCookies(); await ready; http.jar = new CookieJar();
  release(Response.json({ code: 0, data: { b_3: 'official-old-device' } }));
  await assert.rejects(task, { code: 'LOGIN_REQUIRED' });
  assert.equal(await http.jar.getCookieString('https://api.bilibili.com/'), ''); assert.equal(persisted, 0);
});
