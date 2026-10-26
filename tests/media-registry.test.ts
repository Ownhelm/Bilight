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

test('first media read uses a fast official backup, cancels the slow source and reuses the winner', async () => {
  const calls: string[] = [];
  let slowSignal: AbortSignal | undefined, release!: () => void;
  const slow = new Promise<void>(resolve => { release = resolve; });
  const media = new MediaRegistry({} as BiliGateway, (async (url, options) => {
    calls.push(new URL(String(url)).hostname);
    if (String(url).includes('primary.')) {
      slowSignal = options!.signal as AbortSignal;
      await Promise.race([slow, new Promise((_, reject) => slowSignal!.addEventListener('abort', () => reject(slowSignal!.reason), { once: true }))]);
    }
    return new Response('data', { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': 'bytes 0-3/100', 'content-length': '4' } });
  }) as typeof fetch);
  const id = media.register('https://primary.bilivideo.com/video.m4s', 'video', undefined, ['https://backup.akamaized.net/video.m4s']).split('/').pop()!;
  const pending = media.fetch(id, 'bytes=0-3');
  try {
    const result = await Promise.race([pending, new Promise<undefined>(resolve => setTimeout(resolve, 50))]);
    assert.ok(result, 'A slow primary must not hold the first media bytes when a fast backup is available');
    assert.equal(await result.response.text(), 'data');
    assert.equal(slowSignal?.aborted, true);
    const previous = calls.length;
    await (await media.fetch(id, 'bytes=0-3'))!.response.body?.cancel();
    assert.deepEqual(calls.slice(previous), ['backup.akamaized.net']);
  } finally { release(); await pending; }
});

test('a fast HTML or mismatched-range backup cannot beat a valid media response', async () => {
  for (const bad of [
    () => new Response('html', { headers: { 'content-type': 'text/html' } }),
    () => new Response('data', { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': 'bytes 4-7/100', 'content-length': '4' } }),
    () => new Response(null, { status: 416 }),
    () => new Response(null, { status: 302, headers: { location: 'https://127.0.0.1/private' } }),
  ]) {
    const visited: string[] = [];
    const media = new MediaRegistry({} as BiliGateway, (async url => {
      visited.push(String(url));
      if (String(url).includes('backup.')) return bad();
      await new Promise(resolve => setImmediate(resolve));
      return new Response('data', { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': 'bytes 0-3/100', 'content-length': '4' } });
    }) as typeof fetch);
    const id = media.register('https://primary.bilivideo.com/video.m4s', 'video', undefined, ['https://backup.akamaized.net/video.m4s', 'https://127.0.0.1/private']).split('/').pop()!;
    assert.equal(await (await media.fetch(id, 'bytes=0-3'))!.response.text(), 'data');
    assert.ok(visited.every(url => !url.includes('127.0.0.1')));
  }
});

test('caller cancellation stops every pending CDN candidate', async () => {
  const signals: AbortSignal[] = [], caller = new AbortController();
  const media = new MediaRegistry({} as BiliGateway, ((_url, options) => new Promise<Response>((_resolve, reject) => {
    const signal = options!.signal as AbortSignal;
    signals.push(signal);
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  })) as typeof fetch);
  const id = media.register('https://primary.bilivideo.com/video.m4s', 'video', undefined, ['https://backup.akamaized.net/video.m4s']).split('/').pop()!;
  const pending = media.fetch(id, 'bytes=0-3', false, caller.signal);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(signals.length, 2);
  const reason = new DOMException('Playback left', 'AbortError');
  caller.abort(reason);
  await assert.rejects(pending, error => error === reason);
  assert.ok(signals.every(signal => signal.aborted));
});

test('winning CDN response is forwarded before the full body is downloaded', async () => {
  let finish!: () => void;
  const body = new ReadableStream<Uint8Array>({ start(controller) {
    controller.enqueue(new TextEncoder().encode('da'));
    finish = () => { controller.enqueue(new TextEncoder().encode('ta')); controller.close(); };
  } });
  const media = new MediaRegistry({} as BiliGateway, (async url => String(url).includes('backup.')
    ? new Response(body, { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': 'bytes 0-3/100', 'content-length': '4' } })
    : new Response(null, { status: 503 })) as typeof fetch);
  const id = media.register('https://primary.bilivideo.com/video.m4s', 'video', undefined, ['https://backup.akamaized.net/video.m4s']).split('/').pop()!;
  const result = (await media.fetch(id, 'bytes=0-3'))!;
  const reader = result.response.body!.getReader();
  assert.equal(new TextDecoder().decode((await reader.read()).value), 'da');
  finish();
  assert.equal(new TextDecoder().decode((await reader.read()).value), 'ta');
  assert.equal((await reader.read()).done, true);
});

test('large first segments use bounded parallel byte ranges and preserve exact byte order', async () => {
  const size = 4 * 1024 * 1024, start = 12345, ranges: string[] = [];
  let active = 0, peak = 0, release!: () => void;
  const held = new Promise<void>(resolve => { release = resolve; });
  const media = new MediaRegistry({} as BiliGateway, (async (_url, options) => {
    const headers = new Headers(options?.headers), range = headers.get('range')!;
    ranges.push(range);
    const [from, to] = range.slice(6).split('-').map(Number), length = to - from + 1;
    active++; peak = Math.max(peak, active);
    if (length > 1024 * 1024) await held;
    else await new Promise(resolve => setTimeout(resolve, 10));
    active--;
    const bytes = Uint8Array.from({ length }, (_, index) => (from + index) % 251);
    return new Response(bytes, { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': `bytes ${from}-${to}/${20 * 1024 * 1024}`, 'content-length': String(length), etag: '"same-file"' } });
  }) as typeof fetch);
  const id = media.register('https://primary.bilivideo.com/video.m4s', 'video').split('/').pop()!;
  const pending = media.fetch(id, `bytes=${start}-${start + size - 1}`);
  try {
    const result = await Promise.race([pending, new Promise<undefined>(resolve => setTimeout(resolve, 100))]);
    assert.ok(result, 'One slow large range must not gate the complete first segment');
    assert.equal(result.response.headers.get('content-range'), `bytes ${start}-${start + size - 1}/${20 * 1024 * 1024}`);
    assert.equal(result.response.headers.get('content-length'), String(size));
    const bytes = new Uint8Array(await result.response.arrayBuffer());
    assert.deepEqual(bytes, Uint8Array.from({ length: size }, (_, index) => (start + index) % 251));
    assert.equal(ranges.length, 4);
    assert.ok(peak >= 2 && peak <= 3, `Unexpected parallelism ${peak}`);
  } finally { release(); await (await pending)?.response.body?.cancel().catch(() => {}); }
});

test('large ranges fall back to one response when a strong file validator is unavailable', async () => {
  for (const etag of [undefined, 'W/"weak-file"']) {
    const ranges: string[] = [];
    const size = 3 * 1024 * 1024;
    const media = new MediaRegistry({} as BiliGateway, (async (_url, options) => {
      const range = new Headers(options?.headers).get('range')!; ranges.push(range);
      const [from, to] = range.slice(6).split('-').map(Number), length = to - from + 1;
      return new Response(new Uint8Array(length).fill(7), { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': `bytes ${from}-${to}/${size}`, 'content-length': String(length), ...(etag ? { etag } : {}) } });
    }) as typeof fetch);
    const id = media.register('https://primary.bilivideo.com/video.m4s', 'video').split('/').pop()!;
    const response = (await media.fetch(id, `bytes=0-${size - 1}`))!.response;
    assert.equal((await response.arrayBuffer()).byteLength, size);
    assert.deepEqual(ranges, [`bytes=0-${1024 * 1024 - 1}`, `bytes=0-${size - 1}`]);
  }
});

test('parallel ranges tolerate a CDN that ignores conditional Range requests but returns matching validators', async () => {
  const size = 3 * 1024 * 1024;
  const media = new MediaRegistry({} as BiliGateway, (async (_url, options) => {
    const headers = new Headers(options?.headers);
    // Observed CDN behavior: If-Range can produce 200 even when the ETag still matches.
    if (headers.has('if-range')) return new Response('full-file', { status: 200, headers: { etag: '"same-file"', 'content-type': 'video/mp4' } });
    const [from, to] = headers.get('range')!.slice(6).split('-').map(Number), length = to - from + 1;
    return new Response(new Uint8Array(length), { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': `bytes ${from}-${to}/${size}`, 'content-length': String(length), etag: '"same-file"' } });
  }) as typeof fetch);
  const id = media.register('https://primary.bilivideo.com/video.m4s', 'video').split('/').pop()!;
  assert.equal((await (await media.fetch(id, `bytes=0-${size - 1}`))!.response.arrayBuffer()).byteLength, size);
});

test('large ranges use a stable direct mirror even when a shared edge won the small metadata request', async () => {
  const size = 3 * 1024 * 1024, calls: { host: string; range: string }[] = [];
  const media = new MediaRegistry({} as BiliGateway, (async (url, options) => {
    const host = new URL(String(url)).hostname, range = new Headers(options?.headers).get('range')!;
    calls.push({ host, range });
    const [from, to] = range.slice(6).split('-').map(Number), length = to - from + 1;
    if (host.endsWith('bilivideo.com')) await new Promise(resolve => setTimeout(resolve, 2));
    return new Response(new Uint8Array(length), { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': `bytes ${from}-${to}/${size}`, 'content-length': String(length), etag: host.endsWith('akamaized.net') ? `"edge-copy-${from}"` : '"same-file"' } });
  }) as typeof fetch);
  const id = media.register('https://primary.bilivideo.com/video.m4s', 'video', undefined, ['https://edge.akamaized.net/video.m4s']).split('/').pop()!;
  await (await media.fetch(id, 'bytes=0-3'))!.response.body?.cancel();
  const previous = calls.length;
  assert.equal((await (await media.fetch(id, `bytes=0-${size - 1}`))!.response.arrayBuffer()).byteLength, size);
  assert.ok(calls.slice(previous).every(call => call.host === 'primary.bilivideo.com'));
});

test('parallel media rejects changed files and never appends mismatched chunks', async () => {
  const size = 4 * 1024 * 1024;
  const media = new MediaRegistry({} as BiliGateway, (async (_url, options) => {
    const headers = new Headers(options?.headers), range = headers.get('range')!;
    const [from, to] = range.slice(6).split('-').map(Number), length = to - from + 1;
    if (from > 0) assert.equal(headers.has('if-range'), false, 'File identity is verified on returned ranges without triggering CDN conditional-range bugs');
    return new Response(new Uint8Array(length), { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': `bytes ${from}-${to}/${size}`, 'content-length': String(length), etag: from > 0 ? '"different-file"' : '"original-file"' } });
  }) as typeof fetch);
  const id = media.register('https://primary.bilivideo.com/video.m4s', 'video').split('/').pop()!;
  const response = (await media.fetch(id, `bytes=0-${size - 1}`))!.response;
  await assert.rejects(response.arrayBuffer(), { code: 'MEDIA_CHANGED' });
});

test('cancelling a parallel media body cancels its seed and every prefetched reader', async () => {
  const size = 4 * 1024 * 1024;
  let cancelled = 0;
  const media = new MediaRegistry({} as BiliGateway, (async (_url, options) => {
    const range = new Headers(options?.headers).get('range')!;
    const [from, to] = range.slice(6).split('-').map(Number);
    const body = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new Uint8Array([1])); }, cancel() { cancelled++; } });
    return new Response(body, { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': `bytes ${from}-${to}/${size}`, 'content-length': String(to - from + 1), etag: '"same-file"' } });
  }) as typeof fetch);
  const id = media.register('https://primary.bilivideo.com/video.m4s', 'video').split('/').pop()!;
  const response = (await media.fetch(id, `bytes=0-${size - 1}`))!.response;
  await new Promise(resolve => setImmediate(resolve));
  await response.body!.cancel();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(cancelled, 3);
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
