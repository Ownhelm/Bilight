import test from 'node:test';
import assert from 'node:assert/strict';
import type { HistoryItem } from '../shared/types.js';
import { historyDay, historyHref } from '../src/historyRecords.js';

const item: HistoryItem = { bvid: 'BV0000000001', aid: 1, title: 'Video', cover: '', duration: 120, publishedAt: 0, owner: { mid: 7, name: 'UP', avatar: '' }, cid: 42, page: 3, part: 'P3', viewedAt: 1, progress: 23.8 };
test('history resumes the correct part and progress, while completed records restart without autoplay', () => {
  assert.equal(historyHref(item), '/video/BV0000000001?p=3&t=23');
  assert.equal(historyHref({ ...item, progress: -1 }), '/video/BV0000000001?p=3');
  assert.equal(historyHref({ ...item, progress: 120 }), '/video/BV0000000001?p=3');
  assert.equal(historyHref({ ...item, progress: 0 }), '/video/BV0000000001?p=3');
});
test('history date groups use local calendar days including daylight-saving transition dates', () => {
  const now = new Date(2026, 9, 25, 14);
  assert.equal(historyDay(new Date(2026, 9, 25, 0, 1).getTime() / 1000, now), '今天');
  assert.equal(historyDay(new Date(2026, 9, 24, 23, 59).getTime() / 1000, now), '昨天');
  assert.notEqual(historyDay(new Date(2026, 9, 23, 23, 59).getTime() / 1000, now), '昨天');
});
