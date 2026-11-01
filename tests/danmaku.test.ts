import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { EventEmitter } from 'node:events';

// Exercise the shipped engine, exposing its internals only in this test module.
const source = await readFile(new URL('../src/vendor/artplayer-plugin-danmuku.mjs', import.meta.url), 'utf8');
const { Danmuku, Setting } = await import(`data:text/javascript;base64,${Buffer.from(`${source}\nexport { Danmuku, Setting };`).toString('base64')}`);
function harness(t: any, playing = false) {
  const frames = new Map<number, () => Promise<void>>(); let next = 0;
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { requestAnimationFrame(fn: () => Promise<void>) { frames.set(++next, fn); return next; }, cancelAnimationFrame(id: number) { frames.delete(id); } } });
  Object.defineProperty(globalThis, 'Worker', { configurable: true, value: class extends EventTarget { postMessage() {} terminate() {} } });
  t.after(() => { Reflect.deleteProperty(globalThis, 'window'); Reflect.deleteProperty(globalThis, 'Worker'); });
  const art = Object.assign(new EventEmitter(), {
    playing, currentTime: 0, template: { $danmuku: { style: {}, textContent: '' }, $player: { clientWidth: 800 }, $controlsCenter: {} },
    constructor: { utils: { clamp: (n: number, min: number, max: number) => Math.max(min, Math.min(n, max)), errorHandle: assert.ok }, validator() {} }
  });
  const engine = new Danmuku(art, { danmuku: [] });
  return { engine, art, frames, async frame() { const batch = [...frames.values()]; frames.clear(); for (const fn of batch) await fn(); } };
}

test('play followed by playing keeps exactly one animation loop and pause cancels it', async t => {
  const { art, frames, frame } = harness(t);
  art.emit('video:play'); art.emit('video:playing');
  assert.equal(frames.size, 1);
  await frame(); assert.equal(frames.size, 1);
  art.emit('video:pause'); assert.equal(frames.size, 0);
  art.emit('video:playing'); assert.equal(frames.size, 1);
  art.emit('destroy'); assert.equal(frames.size, 0);
  assert.equal(art.listenerCount('resize'), 0);
});

test('normal is the old very-slow duration, with slower choices and no very-fast choice', t => {
  const { engine } = harness(t);
  const setting = Object.assign(Object.create(Setting.prototype), { danmuku: engine });
  assert.equal(engine.option.speed, 10);
  assert.deepEqual(setting.SPEED.steps.map((step: any) => [step.name, step.value]), [['极慢', 20], ['较慢', 15], ['适中', 10], ['较快', 7.5]]);
  for (const speed of [20, 15, 10, 7.5]) { engine.config({ speed }); assert.equal(engine.speed, speed); }
});


test('installing while video is already playing starts the scheduler once', t => {
  const { art, frames } = harness(t, true);
  assert.equal(frames.size, 1);
  art.emit('video:playing'); assert.equal(frames.size, 1);
  art.emit('destroy');
});

test('stopping during async admission cannot resurrect an obsolete animation loop', async t => {
  const { engine, art, frames } = harness(t);
  let admit!: (visible: boolean) => void;
  engine.option.beforeVisible = () => new Promise<boolean>(resolve => { admit = resolve; });
  await engine.emit({ text: 'test', time: 1 });
  art.currentTime = 1; art.playing = true; art.emit('video:play');
  const callback = [...frames.values()][0]; frames.clear();
  const oldFrame = callback();
  art.emit('video:pause'); art.playing = false; art.emit('video:playing');
  admit(true); await oldFrame;
  assert.equal(frames.size, 1);
  art.emit('destroy');
});

test('worker requests have unique IDs, resolve independently and release listeners on destroy', async t => {
  const { engine, art } = harness(t);
  const requests: any[] = [];
  engine.worker.postMessage = (message: any) => requests.push(message);
  const first = engine.postMessage({ type: 'getDanmuTop' });
  const second = engine.postMessage({ type: 'getDanmuTop' });
  assert.notEqual(requests[0].id, requests[1].id);
  engine.worker.dispatchEvent(new MessageEvent('message', { data: { id: requests[1].id, result: 20 } }));
  engine.worker.dispatchEvent(new MessageEvent('message', { data: { id: requests[0].id, result: 10 } }));
  assert.equal((await first).result, 10); assert.equal((await second).result, 20);
  assert.equal(engine.pendingMessages.size, 0);
  const pending = engine.postMessage({ type: 'getDanmuTop' });
  art.emit('destroy'); assert.equal((await pending).result, undefined);
  assert.equal(engine.pendingMessages.size, 0);
});


test('scrolling velocity stays constant across desktop widths while fixed comments keep their duration', t => {
  const { engine } = harness(t);
  for (const speed of [20, 15, 10, 7.5]) {
    engine.config({ speed });
    for (const width of [80, 180, 500]) {
      const expected = (800 + width) / speed;
      for (const clientWidth of [640, 800, 1050, 1440, 2100, 3440]) {
        assert.ok(Math.abs((clientWidth + width) / engine.travelTime({ mode: 0 }, clientWidth, width) - expected) < 1e-9);
        assert.equal(engine.travelTime({ mode: 1 }, clientWidth, width), speed);
        assert.equal(engine.travelTime({ mode: 2 }, clientWidth, width), speed);
      }
    }
  }
});

test('changing danmaku speed or width does not move a 21-minute comment on the video timeline', async t => {
  const { engine, art } = harness(t);
  await engine.emit({ text: '21 minutes', time: 1260 });
  for (const speed of [20, 15, 10, 7.5]) {
    engine.config({ speed });
    for (const width of [800, 1050, 2100]) {
      art.template.$player.clientWidth = width; engine.resize();
      art.currentTime = 1259; assert.equal(engine.readys.length, 0);
      art.currentTime = 1260; assert.equal(engine.readys.length, 1);
      assert.equal(engine.readys[0].time, 1260);
      art.currentTime = 1261; assert.equal(engine.readys.length, 0);
    }
  }
});

test('resizing while paused preserves the scrolling anchor for resume', t => {
  const { engine, art } = harness(t);
  const danmu = { mode: 0, $state: 'stop', $startLeft: 800, $restTime: 6, $ref: { clientWidth: 180, dataset: {}, style: { left: '800px', transform: 'translateX(-392px)' } } };
  engine.states.stop.push(danmu);
  art.template.$player.clientWidth = 2100; engine.resize();
  assert.equal(danmu.$ref.style.left, '800px');
  assert.equal(danmu.$ref.style.transform, 'translateX(-392px)');
  engine.continue();
  assert.equal(danmu.$ref.style.transform, 'translateX(-980px)');
  assert.equal((danmu.$ref.style as any).transition, 'transform 6s linear 0s');
});
