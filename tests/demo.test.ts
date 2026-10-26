import test from 'node:test';
import assert from 'node:assert/strict';

test('publication preview isolates a fictional account and public creator snapshots', async () => {
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
    assert.deepEqual([...new Set(feed.items.map((item: { owner: { name: string } }) => item.owner.name))].sort(), ['小鹿Lawrence', '影视飓风', '超Carry的柴西'].sort());
    const creator = (await app.inject('/api/creators/946974/videos')).json();
    assert.ok(creator.items.length > 0 && creator.items.every((item: { owner: { mid: number } }) => item.owner.mid === 946974));
    const groups = (await app.inject('/api/creators/37029661/collections')).json();
    assert.ok(groups.items.length > 0 && groups.items.every((item: { mid: number }) => item.mid === 37029661));
    assert.equal((await app.inject({ method: 'POST', url: '/api/auth/logout' })).statusCode, 403);
    assert.equal((await app.inject('/api/media/unknown')).statusCode, 404);
    assert.match((await app.inject('/api/auth/state')).headers['content-security-policy']!, /connect-src 'self'/);
  } finally { await app.close(); }
});

test('code-only preview reports missing external images without serving the application HTML', async () => {
  // @ts-expect-error The preview has a dependency-free JavaScript interface.
  const { createDemo } = await import('../scripts/demo.mjs');
  const app = await createDemo({ assetsDir: new URL('./missing-publication-assets', import.meta.url).pathname });
  try {
    const response = await app.inject('/demo-assets/demo-avatar-0.png');
    assert.equal(response.statusCode, 503);
    assert.equal(response.json().error.code, 'DEMO_ASSETS_MISSING');
    assert.equal((await app.inject('/api/following')).json().items.length, 8);
  } finally { await app.close(); }
});
