import test from 'node:test';
import assert from 'node:assert/strict';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TripleActions } from '../src/TripleActions.js';
import { createLikePress, LIKE_HOLD_MS } from '../src/likePress.js';
import { coinChoices, engagementCounts, favoriteChanged, optimisticEngagement } from '../src/interactionModel.js';

test('optimistic icons preserve the previous state and do not invent public totals', () => {
  const before = { liked: true, coins: 1, favorited: false };
  assert.deepEqual(optimisticEngagement(before, 'like'), { ...before, liked: false });
  assert.deepEqual(optimisticEngagement(before, { type: 'coin', coins: 2, selectLike: true }), { ...before, coins: 2 });
  assert.deepEqual(optimisticEngagement(before, 'triple'), { liked: true, coins: 1, favorited: true });
  assert.deepEqual(before, { liked: true, coins: 1, favorited: false });
});

test('a short press likes once, a long press triples once and does not also click like', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let clicks = 0, holds = 0, holding = false;
  const press = createLikePress(() => clicks++, () => holds++, value => { holding = value; });
  press.start(); t.mock.timers.tick(LIKE_HOLD_MS - 1); press.end(); press.click();
  assert.equal(clicks, 1); assert.equal(holds, 0); assert.equal(holding, false);
  press.start(); t.mock.timers.tick(LIKE_HOLD_MS); assert.equal(holding, true); assert.equal(holds, 0);
  t.mock.timers.tick(1600); press.end(); press.click();
  assert.equal(holds, 1); assert.equal(clicks, 1);
});

test('releasing after the 800ms hold threshold cancels charging and suppresses an ordinary like', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] }); let clicks = 0, holds = 0;
  const press = createLikePress(() => clicks++, () => holds++, () => {});
  press.start(); t.mock.timers.tick(800); t.mock.timers.tick(600); press.end(); press.click();
  t.mock.timers.tick(2000); assert.equal(holds, 0); assert.equal(clicks, 0);
});

test('moving away, scrolling, losing focus or unmounting cancels a pending triple', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] }); let clicks = 0, holds = 0;
  const press = createLikePress(() => clicks++, () => holds++, () => {});
  press.start(); t.mock.timers.tick(300); press.cancel(); t.mock.timers.tick(2000); press.click();
  assert.equal(clicks, 0); assert.equal(holds, 0);
  press.start(); press.end(); press.click(); assert.equal(clicks, 1);
  press.start(); press.dispose(); t.mock.timers.tick(2000); assert.equal(holds, 0);
});

test('like, coin and favorite are actual enabled controls before status has loaded', () => {
  const html = renderToStaticMarkup(createElement(TripleActions, { bvid: 'BV0000000001', auth: { authenticated: true }, onLogin() {} }));
  for (const label of ['点赞', '投币', '收藏']) {
    const control = html.match(new RegExp(`<button\\b[^>]*aria-label="${label}"[^>]*>`));
    assert.ok(control, `${label} must be an interactive button, not a status label`);
    assert.ok(!control[0].includes('disabled'), `${label} must work before the initial state read completes`);
  }
});

test('coin choices show only remaining increments and favorite confirmation requires actual changes', () => {
  assert.deepEqual(coinChoices(2, 0), [1, 2]); assert.deepEqual(coinChoices(2, 1), [1]); assert.deepEqual(coinChoices(1, 0), [1]); assert.deepEqual(coinChoices(1, 1), []); assert.deepEqual(coinChoices(2, 2), []);
  const folders = [{ id: 10, title: 'A', count: 1, selected: true }, { id: 20, title: 'B', count: 0, selected: false }];
  assert.equal(favoriteChanged(folders, [10]), false); assert.equal(favoriteChanged(folders, [20]), true); assert.equal(favoriteChanged(folders, []), true);
});

test('toolbar counts use public totals and only the current account delta without accumulating repeated reads', () => {
  const snapshot = { coinLimit: 2 as const, likes: 10, coins: 20, favorites: 30 }, baseline = { liked: false, coins: 0, favorited: true }, state = { liked: true, coins: 1, favorited: false };
  assert.deepEqual(engagementCounts(snapshot, baseline, state), { likes: 11, coins: 21, favorites: 29 });
  assert.deepEqual(engagementCounts(snapshot, baseline, state), { likes: 11, coins: 21, favorites: 29 });
  assert.deepEqual(engagementCounts(snapshot), { likes: 10, coins: 20, favorites: 30 }); assert.equal(engagementCounts(), null);
});

test('an unavailable hold is consumed without animating or writing', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] }); let clicks = 0, holds = 0, holding = false;
  const press = createLikePress(() => clicks++, () => holds++, value => { holding = value; }, () => false);
  press.start(); t.mock.timers.tick(800); t.mock.timers.tick(2000); press.end(); press.click();
  assert.deepEqual({ clicks, holds, holding }, { clicks: 0, holds: 0, holding: false });
});
