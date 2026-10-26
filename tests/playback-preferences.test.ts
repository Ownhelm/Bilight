import assert from 'node:assert/strict';
import test from 'node:test';
import { PlaybackPreferences } from '../src/playbackPreferences';

function storage(initial: string | null = null) {
  let value = initial;
  return { getItem: () => value, setItem: (_key: string, next: string) => { value = next; } };
}

test('explicit danmaku and quality choices survive a fresh browser session, including switching off', () => {
  const disk = storage(), first = new PlaybackPreferences(disk);
  assert.equal(first.danmaku, false); assert.equal(first.quality, 127);
  first.setDanmaku(true); first.setQuality(120);
  const restarted = new PlaybackPreferences(disk);
  assert.equal(restarted.danmaku, true); assert.equal(restarted.quality, 120);
  restarted.setDanmaku(false); restarted.setQuality(64);
  const nextVideo = new PlaybackPreferences(disk);
  assert.equal(nextVideo.danmaku, false); assert.equal(nextVideo.quality, 64);
});

test('invalid persisted values cannot become playback requests; blocked storage still keeps session choices', () => {
  for (const value of ['broken JSON', 'null', '{"danmaku":"false","quality":-1}', '{"quality":9999}', '{"quality":80.5}']) {
    const preferences = new PlaybackPreferences(storage(value));
    assert.equal(preferences.danmaku, false); assert.equal(preferences.quality, 127);
  }
  const preferences = new PlaybackPreferences({ getItem() { throw new Error('blocked'); }, setItem() { throw new Error('blocked'); } });
  preferences.setDanmaku(true); preferences.setQuality(120); preferences.setQuality(NaN);
  assert.equal(preferences.danmaku, true); assert.equal(preferences.quality, 120);
});
