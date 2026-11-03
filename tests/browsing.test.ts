import test from 'node:test';
import assert from 'node:assert/strict';
import { BrowsingSession } from '../src/browsing.js';

const settled = () => new Promise<void>(resolve => setImmediate(resolve));

test('returning to a history entry reuses successful and empty pages without another read', async () => {
  const requests: string[] = [];
  const cache = new BrowsingSession(async url => { requests.push(url); return { items: url.includes('empty') ? [] : ['video'] }; });
  for (const url of ['/search?page=2', '/creator/7/empty']) {
    const first = cache.resource('entry', url, 0); first.load(); first.load(); await settled();
    const unsubscribe = first.subscribe(() => {}); unsubscribe();
    cache.scroll.set('entry', 800);
    const returned = cache.resource('entry', url, 0); returned.load(); await settled();
    assert.equal(returned, first); assert.equal(returned.snapshot().loading, false);
    assert.equal(cache.scroll.get('entry'), 800);
  }
  assert.deepEqual(requests, ['/search?page=2', '/creator/7/empty']);
});

test('refresh retries a real error, resets scroll and does not share data with a new history entry', async () => {
  let reads = 0;
  const cache = new BrowsingSession(async () => { if (++reads === 1) throw new Error('upstream refused'); return { items: ['fresh'] }; });
  const failed = cache.resource('first', '/search', 0); failed.load(); await settled();
  assert.equal(failed.snapshot().error?.message, 'upstream refused');
  cache.resource('first', '/search', 0).load(); await settled(); assert.equal(reads, 1);
  cache.scroll.set('first', 900); cache.refresh('first', value => value + 1);
  assert.equal(cache.scroll.get('first'), 0);
  const refreshed = cache.resource('first', '/search', cache.revision('first')); refreshed.load(); await settled();
  assert.deepEqual(refreshed.snapshot().data, { items: ['fresh'] });
  const newEntry = cache.resource('second', '/search', 0);
  assert.notEqual(newEntry, refreshed); assert.equal(newEntry.snapshot().data, null);
  newEntry.load(); await settled(); assert.equal(reads, 3);
});

test('account disposal aborts pending reads and ignores late responses from the old session', async () => {
  let finish!: (value: unknown) => void, signal!: AbortSignal, updates = 0;
  const cache = new BrowsingSession(async (_url, options) => { signal = options.signal; return new Promise(resolve => { finish = resolve; }); });
  const pending = cache.resource('entry', '/creator/7', 0); pending.subscribe(() => updates++); pending.load();
  cache.scroll.set('entry', 500); cache.refresh('entry', 1); cache.clear();
  assert.equal(signal.aborted, true); assert.equal(cache.scroll.size, 0); assert.equal(cache.revision('entry'), 0);
  finish({ items: ['old account'] }); await settled();
  assert.equal(pending.snapshot().data, null); assert.equal(updates, 0);
  assert.notEqual(cache.resource('entry', '/creator/7', 0), pending);
});

test('effect replay keeps pending work alive, while the final detach cancels it', async () => {
  let signal!: AbortSignal, reads = 0;
  const cache = new BrowsingSession(async (_url, options) => { reads++; signal = options.signal; return new Promise(() => {}); });
  const detach = cache.attach(); const resource = cache.resource('entry', '/search', 0); resource.load();
  detach(); const finalDetach = cache.attach(); await settled();
  resource.load(); assert.equal(signal.aborted, false); assert.equal(reads, 1);
  finalDetach(); await settled(); assert.equal(signal.aborted, true);
});
