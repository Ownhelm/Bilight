import test from 'node:test';
import assert from 'node:assert/strict';
import { api, ApiError } from '../src/api.js';

test('silent interaction failures still clear an expired account without requesting an error notice', async t => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'window'), window = new EventTarget();
  Object.defineProperty(globalThis, 'window', { configurable: true, value: window });
  t.after(() => { if (previous) Object.defineProperty(globalThis, 'window', previous); else Reflect.deleteProperty(globalThis, 'window'); });
  const events: boolean[] = [];
  window.addEventListener('bilight:session-expired', event => events.push((event as CustomEvent).detail.silent));
  const mockedFetch = t.mock.method(globalThis, 'fetch', async () => new Response(JSON.stringify({ error: { code: 'LOGIN_REQUIRED', message: 'Test-only expired session' } }), { status: 401 }));
  await assert.rejects(api('/api/videos/test/interaction', { method: 'POST', silentAuthFailure: true }), error => error instanceof ApiError && error.code === 'LOGIN_REQUIRED');
  await assert.rejects(api('/api/auth/state'), ApiError);
  assert.deepEqual(events, [true, false], 'Both failures invalidate the account; ordinary reads retain their normal visible error policy');
  const controller = new AbortController();
  mockedFetch.mock.mockImplementation(async () => {
    const response = new Response('', { status: 401 });
    Object.defineProperty(response, 'json', { value: async () => { controller.abort(); return {}; } });
    return response;
  });
  await assert.rejects(api('/api/videos/old/engagement', { signal: controller.signal }), error => error instanceof DOMException && error.name === 'AbortError');
  assert.deepEqual(events, [true, false], 'An aborted old-account response cannot invalidate a newer account');
});
