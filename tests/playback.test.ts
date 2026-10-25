import test from 'node:test';
import assert from 'node:assert/strict';
import type { Subtitle } from '../shared/types.js';
import { defaultSubtitle, installProgressShortcuts, qualitySetting } from '../src/playback.js';
import type { SettingOption } from 'artplayer';
import type Artplayer from 'artplayer';
import { switchPlaybackSource } from '../src/playback.js';
import { EventEmitter } from 'node:events';

const subtitle = (id: string, lang: string): Subtitle => ({ id, lang, label: lang, url: `/api/media/${id}/subtitle.vtt` });

function progressTarget() {
  class TestDocument extends EventTarget { activeElement: unknown = null; modal = false; querySelector() { return this.modal ? {} : null; } }
  const document = new TestDocument(), keys: Record<string, ((event: KeyboardEvent) => void)[]> = {};
  const player = { currentTime: 20, duration: 60, playing: false, video: { readyState: 1 }, notice: { show: '' }, hotkey: { keys, add(key: string, fn: (event: KeyboardEvent) => void) { (keys[key] ??= []).push(fn); return this; }, remove(key: string, fn: (event: KeyboardEvent) => void) { keys[key] = (keys[key] ?? []).filter(item => item !== fn); return this; } } };
  const original = () => { player.currentTime += 5; };
  player.hotkey.add('ArrowRight', original);
  // Model ArtPlayer's earlier document listener: it must not seek a second time.
  document.addEventListener('keydown', event => { for (const fn of keys[(event as KeyboardEvent).key] ?? []) fn(event as KeyboardEvent); });
  let switching = false;
  const cleanup = installProgressShortcuts(player as unknown as Artplayer, document as unknown as Document, () => switching);
  const press = (key: string, extra = {}) => { const event = Object.assign(new Event('keydown', { cancelable: true }), { key, ...extra }); document.dispatchEvent(event); return event; };
  return { player, document, press, cleanup, original, setSwitching(value: boolean) { switching = value; } };
}

test('left/right seek from the page without player focus, preserve pause and play, and never double seek', () => {
  const { player, press, cleanup } = progressTarget();
  assert.equal(press('ArrowRight').defaultPrevented, true); assert.equal(player.currentTime, 25); assert.equal(player.playing, false); assert.match(player.notice.show, /快进 5 秒.*00:25/);
  player.playing = true; press('ArrowLeft'); assert.equal(player.currentTime, 20); assert.equal(player.playing, true);
  press('ArrowRight', { repeat: true }); press('ArrowRight', { repeat: true }); assert.equal(player.currentTime, 30);
  cleanup();
});

test('seeking clamps at both ends and works during buffering after metadata is ready', () => {
  const { player, press, cleanup, setSwitching } = progressTarget();
  player.currentTime = 2; press('ArrowLeft'); assert.equal(player.currentTime, 0); press('ArrowLeft'); assert.match(player.notice.show, /视频开头/);
  player.currentTime = 59; press('ArrowRight'); assert.equal(player.currentTime, 60); press('ArrowRight'); assert.match(player.notice.show, /视频结尾/);
  player.currentTime = 20; player.video.readyState = 0; assert.equal(press('ArrowRight').defaultPrevented, false); assert.equal(player.currentTime, 20);
  player.video.readyState = 1; setSwitching(true); press('ArrowRight'); assert.equal(player.currentTime, 20);
  setSwitching(false); press('ArrowRight'); assert.equal(player.currentTime, 25); cleanup();
});

test('progress keys leave inputs, menus, dialogs, modifiers and composition alone; teardown restores defaults', () => {
  const { player, document, press, cleanup, original } = progressTarget();
  for (const control of [{ isContentEditable: true }, { closest: () => ({}) }]) { document.activeElement = control; assert.equal(press('ArrowRight').defaultPrevented, false); }
  document.activeElement = null; document.modal = true; press('ArrowRight'); document.modal = false;
  for (const modifier of ['ctrlKey', 'metaKey', 'altKey', 'shiftKey', 'isComposing']) assert.equal(press('ArrowRight', { [modifier]: true }).defaultPrevented, false);
  assert.equal(player.currentTime, 20);
  const handled = Object.assign(new Event('keydown', { cancelable: true }), { key: 'ArrowRight' }); handled.preventDefault(); document.dispatchEvent(handled); assert.equal(player.currentTime, 20);
  cleanup(); assert.ok(player.hotkey.keys.ArrowRight.includes(original)); press('ArrowLeft'); assert.equal(player.currentTime, 20);
});
test('subtitles default to available Chinese, then the first available language, without inventing a track', () => {
  assert.equal(defaultSubtitle([subtitle('english', 'en'), subtitle('ai', 'ai-zh'), subtitle('chinese', 'zh-CN')]), 'chinese');
  assert.equal(defaultSubtitle([subtitle('english', 'en'), subtitle('ai', 'ai-zh')]), 'ai');
  assert.equal(defaultSubtitle([subtitle('english', 'en'), subtitle('japanese', 'ja')]), 'english');
  assert.equal(defaultSubtitle([]), '');
});

function switchTarget() {
  const events = new EventEmitter();
  const target = { currentTime: 15, playbackRate: 1.5, playing: false, url: 'old', pause() { target.playing = false; }, async play() { target.playing = true; }, on(name: string, fn: (...args: any[]) => void) { events.on(name, fn); }, off(name: string, fn: (...args: any[]) => void) { events.off(name, fn); }, switchQuality() { return new Promise<void>(() => {}); } };
  return { target: target as unknown as Artplayer, events };
}

test('a stalled source switch releases its listeners and lock when cancelled, without resuming playback', async () => {
  const { target, events } = switchTarget(); const controller = new AbortController();
  const pending = switchPlaybackSource(target, 'new', { signal: controller.signal, position: { time: 15, playing: false, rate: 1.5 }, timeoutMs: 100 });
  controller.abort();
  const result = await Promise.race([pending.then(() => 'unexpected success', error => error.name), new Promise(resolve => setTimeout(() => resolve('stalled'), 30))]);
  assert.equal(result, 'AbortError'); assert.equal(target.playing, false); assert.equal(events.eventNames().length, 0);
});

test('a source switch restores position and rate, stays paused, and removes all temporary handlers', async () => {
  const { target, events } = switchTarget(); const controller = new AbortController();
  const pending = switchPlaybackSource(target, 'new', { signal: controller.signal, position: { time: 23, playing: false, rate: 2 } });
  assert.equal(target.url, 'new'); events.emit('video:loadedmetadata'); events.emit('video:canplay'); await pending;
  assert.equal(target.currentTime, 23); assert.equal(target.playbackRate, 2); assert.equal(target.playing, false); assert.equal(events.eventNames().length, 0);
});

test('a source switch resumes only a previously playing video and fails promptly on timeout or media error', async () => {
  const { target, events } = switchTarget();
  const pending = switchPlaybackSource(target, 'new', { signal: new AbortController().signal, position: { time: 4, playing: true, rate: 1.5 } });
  events.emit('video:loadedmetadata'); events.emit('video:canplay'); await pending;
  assert.equal(target.playing, true); assert.equal(target.currentTime, 4); assert.equal(events.eventNames().length, 0);
  await assert.rejects(switchPlaybackSource(target, 'slow', { signal: new AbortController().signal, position: { time: 4, playing: true, rate: 1.5 }, timeoutMs: 5 }), /超时/);
  assert.equal(events.eventNames().length, 0);
  const failed = switchPlaybackSource(target, 'bad', { signal: new AbortController().signal, position: { time: 4, playing: true, rate: 1.5 } });
  events.emit('video:error'); await assert.rejects(failed, /失败/); assert.equal(events.eventNames().length, 0);
});

test('player settings list only available qualities and select the actual active stream', async () => {
  const selected: number[] = [];
  const setting = qualitySetting({ cid: 1, quality: 112, qualities: [{ id: 112, label: '1080P+' }, { id: 80, label: '1080P' }, { id: 64, label: '720P' }], subtitles: [] }, async id => { selected.push(id); return '720P'; });
  assert.equal(setting.html, '清晰度'); assert.equal(setting.tooltip, '1080P+');
  assert.deepEqual(setting.selector?.map(item => [item.value, item.default]), [[112, true], [80, false], [64, false]]);
  assert.equal(await setting.onSelect!.call(null as never, setting.selector![2] as SettingOption, null as never, null as never), '720P');
  assert.deepEqual(selected, [64]);
});

test('quality setting renders upstream labels as text and reports the returned quality after selection', async () => {
  const setting = qualitySetting({ cid: 1, quality: 80, qualities: [{ id: 80, label: '<img src=x> & "HD"' }], subtitles: [] }, async () => '1080P+');
  assert.equal(setting.tooltip, '&lt;img src=x&gt; &amp; &quot;HD&quot;');
  assert.equal(setting.selector?.[0].html, setting.tooltip);
  assert.equal(await setting.onSelect!.call(null as never, setting.selector![0] as SettingOption, null as never, null as never), '1080P+');
});
