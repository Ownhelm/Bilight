import test from 'node:test';
import assert from 'node:assert/strict';
import { observeWatchProgress } from '../src/watchHistory.js';

class TestVideo extends EventTarget {
  currentTime = 0; duration = 60; paused = true; seeking = false; playbackRate = 1;
  emit(event: string) { this.dispatchEvent(new Event(event)); }
  play() { this.paused = false; this.emit('playing'); }
  advance(time: number) { this.currentTime = time; this.emit('timeupdate'); }
  pause() { this.paused = true; this.emit('pause'); }
}

test('opening, preloading or seeking a paused video never creates history; playing is throttled and pause flushes', () => {
  const video = new TestVideo(), records: [number, boolean][] = []; let now = 0;
  const observer = observeWatchProgress(video, (...input) => records.push(input), () => now);
  video.advance(10); video.emit('seeking'); video.advance(30); video.emit('seeked'); video.pause(); observer.flush();
  assert.deepEqual(records, []);
  video.play(); video.advance(30.5); assert.deepEqual(records, [[30.5, false]]);
  now = 1000; video.advance(31); video.advance(32); assert.equal(records.length, 1);
  now = 15_000; video.advance(33); assert.deepEqual(records.at(-1), [33, false]);
  video.advance(34); video.pause(); assert.deepEqual(records.at(-1), [34, false]);
  const count = records.length; observer.dispose(); video.play(); video.advance(35); assert.equal(records.length, count);
});

test('part changes/page leave flush the last real progress, ended marks completion, and late attachment still records', () => {
  const video = new TestVideo(), records: [number, boolean][] = []; video.play();
  const observer = observeWatchProgress(video, (...input) => records.push(input), () => 0);
  video.advance(1); video.advance(2); observer.flush(); assert.deepEqual(records.at(-1), [2, false]);
  video.seeking = true; video.currentTime = 59; video.emit('seeking'); video.emit('timeupdate'); video.seeking = false; video.emit('seeked');
  video.advance(60); video.emit('ended'); assert.deepEqual(records.at(-1), [60, true]);
  observer.dispose(); assert.equal(records.filter(record => record[1]).length, 1);
});
