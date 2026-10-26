import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import test from 'node:test';
import { createApp } from '../server/app.js';
import { MediaRegistry } from '../server/media.js';
import type { AuthService } from '../server/auth.js';
import type { BiliGateway, PlaybackSource } from '../server/gateway.js';

const host = { host: '127.0.0.1:3880' };
const original: PlaybackSource = { cid: 42, quality: 80, duration: 90, qualities: [{ id: 80, label: '1080P' }], subtitles: [], video: { id: 80, baseUrl: 'https://test.bilivideo.com/video.m4s?token=old', mimeType: 'video/mp4', codecs: 'avc1.640028', bandwidth: 100000, width: 1920, height: 1080, segmentBase: { initialization: '0-999', indexRange: '1000-2000' } } };
const anonymous = { state: async () => ({ authenticated: false }), logout: async () => {} } as unknown as AuthService;

test('expired DASH media rejects a changed rendition instead of attaching new bytes to an old MPD', async () => {
  const downgraded: PlaybackSource = { ...original, quality: 16, video: { ...original.video!, id: 16, baseUrl: 'https://test.bilivideo.com/video.m4s?token=new', width: 426, height: 240, segmentBase: { initialization: '0-99', indexRange: '100-200' } } };
  const gateway = { playback: async () => downgraded } as unknown as BiliGateway;
  let downloads = 0;
  const media = new MediaRegistry(gateway, (async () => ++downloads === 1 ? new Response(null, { status: 403 }) : new Response('wrong-rendition', { status: 206, headers: { 'content-type': 'video/mp4' } })) as typeof fetch);
  const playback = media.playback(original, 'BV17x411w7KC');
  const mpd = media.manifest(playback.manifestUrl!.split('/')[3])!;
  const resource = mpd.match(/<BaseURL>([^<]+)<\/BaseURL>/)![1].split('/').pop()!;
  await assert.rejects(media.fetch(resource, 'bytes=2001-3000'), (error: unknown) => error instanceof Error && (error as Error & { status?: number }).status === 409);
  assert.equal(downloads, 1, 'a different encoding must not be downloaded with the old byte ranges');
});

test('expired CDN alternatives are refreshed together without changing rendition or requested bytes', async () => {
  const urls: string[] = [];
  let renewals = 0;
  const initial = { ...original, video: { ...original.video!, backupUrl: ['https://backup.akamaized.net/video.m4s?token=old'] } };
  const renewed = { ...initial, video: { ...initial.video, baseUrl: 'https://test.bilivideo.com/video.m4s?token=new', backupUrl: ['https://backup.akamaized.net/video.m4s?token=new'] } };
  const gateway = { playback: async () => { renewals++; return renewed; } } as unknown as BiliGateway;
  const media = new MediaRegistry(gateway, (async (url, options) => {
    urls.push(String(url));
    assert.equal(new Headers(options?.headers).get('range'), 'bytes=2001-2004');
    if (!String(url).includes('backup.') || !String(url).includes('token=new')) return new Response(null, { status: 403 });
    return new Response('data', { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': 'bytes 2001-2004/3000', 'content-length': '4' } });
  }) as typeof fetch);
  const mapped = media.playback(initial, 'BV17x411w7KC');
  const manifest = media.manifest(mapped.manifestUrl!.split('/')[3])!;
  const id = manifest.match(/<BaseURL>([^<]+)<\/BaseURL>/)![1].split('/').pop()!;
  assert.equal(await (await media.fetch(id, 'bytes=2001-2004'))!.response.text(), 'data');
  assert.equal(renewals, 1);
  assert.ok(urls.some(url => url.includes('backup.') && url.includes('token=new')));
  assert.ok(!manifest.includes('token='));
});

test('video and audio proxy routes reject executable upstream content served as HTML', async t => {
  const gateway = {} as BiliGateway;
  const media = new MediaRegistry(gateway, (async () => new Response('<script>window.localOriginExecuted = true</script>', { headers: { 'content-type': 'text/html' } })) as typeof fetch);
  const app = await createApp({ auth: anonymous, gateway, media, key: randomBytes(32), staticDir: '/nonexistent' });
  t.after(() => app.close());
  for (const kind of ['video', 'audio'] as const) {
    const resource = media.register(`https://test.bilivideo.com/${kind}.m4s`, kind);
    const response = await app.inject({ url: resource, headers: host });
    assert(response.statusCode >= 400 && response.statusCode < 600, `${kind} unexpectedly returned ${response.statusCode}`);
    assert(!String(response.headers['content-type']).includes('text/html'));
    assert(!response.body.includes('<script>'));
  }
});

test('encoded static API paths receive the same CSRF protection as canonical paths', async t => {
  let logouts = 0;
  const auth = { ...anonymous, logout: async () => { logouts++; } } as unknown as AuthService;
  const app = await createApp({ auth, gateway: {} as BiliGateway, key: randomBytes(32), staticDir: '/nonexistent' });
  t.after(() => app.close());
  const response = await app.inject({ method: 'POST', url: '/%61pi/auth/logout', headers: host });
  assert.equal(response.statusCode, 403);
  assert.equal(logouts, 0, 'encoded routing must never bypass the mutation guard');
});
