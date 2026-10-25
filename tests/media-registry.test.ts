import assert from 'node:assert/strict';
import test from 'node:test';
import type { BiliGateway } from '../server/gateway.js';
import { MediaRegistry } from '../server/media.js';

test('register replaces expired media IDs while reusing live IDs', async t => {
  let now = Date.now();
  t.mock.method(Date, 'now', () => now);
  const media = new MediaRegistry({} as BiliGateway, (async () => new Response('image', { headers: { 'content-type': 'image/jpeg' } })) as typeof fetch);
  const url = 'https://test.hdslb.com/avatar.jpg';
  const original = media.register(url, 'image');
  assert.equal(media.register(url, 'image'), original);
  assert((await media.fetch(original.split('/').pop()!))?.response.ok);
  now += 86_400_001;
  const replacement = media.register(url, 'image');
  assert.notEqual(replacement, original, 'a fresh registration must not inherit an expired resource ID');
  assert.equal(await media.fetch(original.split('/').pop()!), undefined);
  assert((await media.fetch(replacement.split('/').pop()!))?.response.ok);
  assert.equal(media.register(url, 'image'), replacement);
});

test('media timeout still cancels an upstream request when a caller signal is supplied', async t => {
  const timeout = new AbortController();
  let timeouts = 0;
  t.mock.method(AbortSignal, 'timeout', (delay: number) => { assert.equal(delay, 60_000); timeouts++; return timeout.signal; });
  const caller = new AbortController();
  let signal: AbortSignal | undefined;
  let started!: () => void;
  const entered = new Promise<void>(resolve => { started = resolve; });
  const media = new MediaRegistry({} as BiliGateway, ((_url, options) => new Promise<Response>((_resolve, reject) => {
    signal = options?.signal as AbortSignal;
    signal.addEventListener('abort', () => reject(signal!.reason), { once: true });
    started();
  })) as typeof fetch);
  const id = media.register('https://test.bilivideo.com/video.m4s', 'video').split('/').pop()!;
  const pending = media.fetch(id, 'bytes=0-100', false, caller.signal);
  await entered;
  assert.equal(timeouts, 1, 'caller cancellation must not replace the upstream request timeout');
  assert.notEqual(signal, caller.signal);
  const reason = new DOMException('test timeout', 'TimeoutError');
  timeout.abort(reason);
  await assert.rejects(pending, error => error === reason);
  assert.equal(caller.signal.aborted, false);
});

test('caller cancellation still cancels redirected media requests with their own timeout', async t => {
  let timeouts = 0;
  t.mock.method(AbortSignal, 'timeout', (delay: number) => { assert.equal(delay, 60_000); timeouts++; return new AbortController().signal; });
  const caller = new AbortController();
  let downloads = 0;
  let started!: () => void;
  const entered = new Promise<void>(resolve => { started = resolve; });
  const media = new MediaRegistry({} as BiliGateway, ((_url, options) => {
    if (++downloads === 1) return Promise.resolve(new Response(null, { status: 302, headers: { location: 'https://other.bilivideo.com/video.m4s' } }));
    return new Promise<Response>((_resolve, reject) => {
      const signal = options?.signal as AbortSignal;
      signal.addEventListener('abort', () => reject(signal.reason), { once: true });
      started();
    });
  }) as typeof fetch);
  const id = media.register('https://test.bilivideo.com/video.m4s', 'video').split('/').pop()!;
  const pending = media.fetch(id, 'bytes=0-100', false, caller.signal);
  await entered;
  assert.equal(timeouts, 2, 'each redirect request must retain a timeout');
  const reason = new DOMException('test caller cancellation', 'AbortError');
  caller.abort(reason);
  await assert.rejects(pending, error => error === reason);
});
