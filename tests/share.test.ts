import test from 'node:test';
import assert from 'node:assert/strict';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { videoShareUrl } from '../src/ShareVideo.js';
import { TripleActions } from '../src/TripleActions.js';

test('external sharing uses the public Bilibili URL and only the selected part', () => {
  assert.equal(videoShareUrl('BV1xx411c7mD'), 'https://www.bilibili.com/video/BV1xx411c7mD/');
  assert.equal(videoShareUrl('BV1xx411c7mD', 3), 'https://www.bilibili.com/video/BV1xx411c7mD/?p=3');
  for (const page of [0, -1, NaN, Infinity, 1.5]) assert.equal(new URL(videoShareUrl('BV1xx411c7mD', page)).search, '');
});

test('anonymous viewers can share after the three engagement controls without logging in', () => {
  const html = renderToStaticMarkup(createElement(TripleActions, { bvid: 'BV1xx411c7mD', auth: null, onLogin() { throw new Error('Sharing must not need login'); } }));
  assert.match(html, /<button\b(?=[^>]*aria-label="转发")(?![^>]*disabled)[^>]*>/);
  assert.ok(html.indexOf('aria-label="转发"') > html.indexOf('aria-label="收藏"'));
});
