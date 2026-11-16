import test from 'node:test';
import assert from 'node:assert/strict';
import { ApiError } from '../src/api.js';
import { DynamicLikes } from '../src/dynamicLikes.js';
import type { DynamicLikeState } from '../shared/types.js';

function deferred<T>() {
  let resolve!: (value: T) => void, reject!: (error: Error) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}
const id = '1057955152016703512';
const initial = { liked: false, likes: 12 };
const settle = () => new Promise<void>(done => setImmediate(done));

test('rapid taps update the visible count and only send the last target after a quiet period', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const writes: boolean[] = [];
  const gate = deferred<DynamicLikeState>();
  const store = new DynamicLikes(async (_id, target) => { writes.push(target); return gate.promise; });
  const display = () => store.getSnapshot().pending[id] ?? store.getSnapshot().states[id];
  store.ingest(id, initial, store.readVersion());
  store.toggle(id, initial);
  assert.deepEqual(display(), { liked: true, likes: 13 });
  t.mock.timers.tick(500);
  store.toggle(id, initial);
  assert.deepEqual(display(), initial);
  t.mock.timers.tick(500);
  store.toggle(id, initial);
  assert.deepEqual(display(), { liked: true, likes: 13 });
  const staleRead = store.readVersion();
  store.ingest(id, { liked: false, likes: 30 }, staleRead);
  assert.deepEqual(display(), { liked: true, likes: 13 });
  t.mock.timers.tick(799);
  await settle();
  assert.deepEqual(writes, []);
  t.mock.timers.tick(1);
  await settle();
  assert.deepEqual(writes, [true]);
  gate.resolve({ liked: true, likes: 21 });
  await settle();
  assert.deepEqual(display(), { liked: true, likes: 21 });
  assert.deepEqual(store.getSnapshot().pending, {});
  store.ingest(id, initial, staleRead);
  assert.deepEqual(display(), { liked: true, likes: 21 });
});

test('tapping back to the original state makes no write, with independent timing for other posts', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const other = '1057955152016703513';
  const writes: string[] = [];
  const store = new DynamicLikes(async key => {
    writes.push(key);
    return { liked: true, likes: 13 };
  });
  store.toggle(id, initial);
  store.toggle(other, initial);
  t.mock.timers.tick(700);
  store.toggle(id, initial);
  t.mock.timers.tick(100);
  await settle();
  assert.deepEqual(writes, [other]);
  t.mock.timers.tick(700);
  await settle();
  assert.deepEqual(writes, [other]);
  assert.equal(store.getSnapshot().pending[id], undefined);
  assert.deepEqual(store.getSnapshot().states[id], initial);
});

test('an older confirmation cannot change the displayed count and the final target is serialized', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const first = deferred<DynamicLikeState>(), second = deferred<DynamicLikeState>();
  const writes: boolean[] = [];
  const store = new DynamicLikes(async (_id, target) => {
    writes.push(target);
    return writes.length === 1 ? first.promise : second.promise;
  });
  store.toggle(id, initial);
  t.mock.timers.tick(800);
  await settle();
  store.toggle(id, initial);
  assert.deepEqual(store.getSnapshot().pending[id], initial);
  t.mock.timers.tick(800);
  await settle();
  assert.deepEqual(writes, [true]);
  first.resolve({ liked: true, likes: 21 });
  await settle();
  assert.deepEqual(store.getSnapshot().pending[id], initial);
  assert.deepEqual(writes, [true, false]);
  second.resolve({ liked: false, likes: 20 });
  await settle();
  assert.deepEqual(store.getSnapshot().states[id], { liked: false, likes: 20 });
  assert.deepEqual(store.getSnapshot().pending, {});
});

test('a newer opposite target is checked after an uncertain write and a rejected final target rolls back', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const first = deferred<DynamicLikeState>();
  const writes: boolean[] = [];
  const store = new DynamicLikes(async (_id, target) => {
    writes.push(target);
    if (writes.length === 1) return first.promise;
    if (writes.length === 2) return { liked: false, likes: 19 };
    throw new ApiError('TOO_MANY_REQUESTS', 'Risk control', 429);
  });
  store.toggle(id, initial);
  t.mock.timers.tick(800);
  store.toggle(id, initial);
  t.mock.timers.tick(800);
  first.reject(new ApiError('DYNAMIC_LIKE_UNCONFIRMED', 'Unavailable', 502));
  await settle();
  assert.deepEqual(writes, [true, false]);
  assert.deepEqual(store.getSnapshot().states[id], { liked: false, likes: 19 });
  assert.deepEqual(store.getSnapshot().errors, {});
  store.toggle(id, initial);
  assert.deepEqual(store.getSnapshot().pending[id], { liked: true, likes: 20 });
  t.mock.timers.tick(800);
  await settle();
  assert.deepEqual(writes, [true, false, true]);
  assert.deepEqual(store.getSnapshot().states[id], { liked: false, likes: 19 });
  assert.deepEqual(store.getSnapshot().pending, {});
  assert.equal(store.getSnapshot().errors[id], 'Risk control');
});

test('account clearing cancels queued work and ignores late confirmations', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const gate = deferred<DynamicLikeState>();
  const writes: string[] = [];
  let signal: AbortSignal | undefined;
  const store = new DynamicLikes(async (key, _target, current) => {
    writes.push(key);
    signal = current;
    return gate.promise;
  });
  store.toggle(id, initial);
  t.mock.timers.tick(800);
  await settle();
  store.toggle('1057955152016703513', initial);
  store.clear();
  assert.equal(signal?.aborted, true);
  t.mock.timers.tick(800);
  gate.resolve({ liked: true, likes: 99 });
  await settle();
  assert.deepEqual(writes, [id]);
  assert.deepEqual(store.getSnapshot(), { states: {}, pending: {}, errors: {} });
});
