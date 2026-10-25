import test from 'node:test';
import assert from 'node:assert/strict';
import type { VideoSummary } from '../shared/types.js';
import { completeFollowingRows, followingColumns, mergeFollowing, nextFollowingCursor } from '../src/following.js';

const video = (bvid: string, publishedAt: number, title = bvid): VideoSummary => ({ bvid, publishedAt, title, aid: 1, cover: '', duration: 10, owner: { mid: 42, name: '关注的 UP 主', avatar: '' } });

test('a scrolling following feed merges overlapping pages in publication order without repeating videos', () => {
  const first = [video('BV1xx411c7mD', 30), video('BV17x411w7KC', 20)];
  const original = [...first];
  const combined = mergeFollowing(first, [video('BV17x411w7KC', 20, 'Updated title'), video('BV1xx411c7mE', 10), video('BV1xx411c7mF', 40)]);
  assert.deepEqual(combined.map(item => item.publishedAt), [40, 30, 20, 10]);
  assert.equal(combined.length, 4);
  assert.equal(combined.find(item => item.bvid === 'BV17x411w7KC')?.title, 'Updated title');
  assert.deepEqual(first, original, 'appending a page must preserve the currently rendered array');
  assert.deepEqual(mergeFollowing(combined, []), combined, 'a filtered empty page must retain earlier videos');
});

test('following cursors stop both immediate repeats and multi-page cycles, while filtered pages remain navigable', () => {
  const visited = new Set(['']);
  assert.equal(nextFollowingCursor({ items: [], hasMore: true, nextCursor: 'cursor-one' }, visited), 'cursor-one');
  visited.add('cursor-one');
  assert.equal(nextFollowingCursor({ items: [], hasMore: true, nextCursor: 'cursor-two' }, visited), 'cursor-two');
  visited.add('cursor-two');
  assert.equal(nextFollowingCursor({ items: [], hasMore: true, nextCursor: 'cursor-two' }, visited), null);
  assert.equal(nextFollowingCursor({ items: [], hasMore: true, nextCursor: 'cursor-one' }, visited), null);
  assert.equal(nextFollowingCursor({ items: [], hasMore: false, nextCursor: 'cursor-three' }, visited), null);
  assert.equal(nextFollowingCursor({ items: [], hasMore: true }, visited), null);
});

test('following buffers incomplete rows across upstream pages at every responsive column count', () => {
  const first = Array.from({ length: 17 }, (_, i) => video(`BV${String(i).padStart(10, '0')}`, 100 - i));
  const second = Array.from({ length: 19 }, (_, i) => video(`BV${String(i + 17).padStart(10, '0')}`, 83 - i));
  for (const columns of [2, 3, 4]) {
    const initial = completeFollowingRows(first, columns, true);
    assert.equal(initial.length % columns, 0);
    assert.equal(initial.length, columns === 3 ? 15 : 16);
    const merged = mergeFollowing(first, second);
    const next = completeFollowingRows(merged, columns, true);
    assert.equal(next.length, 36);
    assert.equal(next.length % columns, 0);
    assert.ok(first.every(item => next.some(shown => shown.bvid === item.bvid)), 'buffered videos must appear with the next completed row');
  }
  assert.deepEqual(completeFollowingRows(first, 4, false), first, 'the real final page must not discard remaining videos or invent padding');
  assert.equal(completeFollowingRows(first.slice(0, 3), 4, true).length, 0);
});

test('following row size matches existing two, three and four column CSS breakpoints', () => {
  for (const width of [375, 640]) assert.equal(followingColumns(width), 2);
  for (const width of [641, 900, 1100]) assert.equal(followingColumns(width), 3);
  for (const width of [1101, 1280, 1920]) assert.equal(followingColumns(width), 4);
});
