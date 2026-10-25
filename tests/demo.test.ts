import test from 'node:test';
import assert from 'node:assert/strict';

test('publication preview is isolated, fictional and read-only', async () => {
  // The preview never imports the real gateway or creates a credential store.
  // @ts-expect-error The standalone preview is an intentionally dependency-free JS entry point.
  const { createDemo } = await import('../scripts/demo.mjs');
  const app = await createDemo();
  try {
    const state = (await app.inject('/api/auth/state')).json();
    assert.equal(state.user.name, 'Bilight 演示');
    const feed = (await app.inject('/api/following')).json();
    assert.equal(feed.items.length, 8);
    assert.ok(feed.items.every((item: { cover: string }) => item.cover.startsWith('/demo-assets/demo-')));
    assert.equal((await app.inject({ method: 'POST', url: '/api/auth/logout' })).statusCode, 403);
    assert.equal((await app.inject('/api/media/unknown')).statusCode, 404);
    assert.match((await app.inject('/api/auth/state')).headers['content-security-policy']!, /connect-src 'self'/);
  } finally { await app.close(); }
});
