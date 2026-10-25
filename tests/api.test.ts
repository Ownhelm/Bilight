import test from 'node:test';
import assert from 'node:assert/strict';
import { api } from '../src/api.js';

test('an aborted response body must reject instead of returning a successful empty following page', async t => {
  const controller = new AbortController();
  const response = new Response('{}');
  t.mock.method(response, 'json', async () => { controller.abort(); throw controller.signal.reason; });
  t.mock.method(globalThis, 'fetch', async () => response);
  await assert.rejects(api('/api/following', { signal: controller.signal }), (error: unknown) => error instanceof DOMException && error.name === 'AbortError');
});
