// Run through Playwright CLI's run-code against a local Vite or preview server.
// All API responses are offline fixtures; no real account, session or engagement writes.
async page => {
  const baseURL = new URL(page.url()).origin;
  const image = 'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/%3E';
  const errors = [], writes = [], rows = [];
  const onConsole = message => { if (/same key/.test(message.text())) errors.push(message.text()); };
  const onError = error => errors.push(error.message);
  page.on('console', onConsole); page.on('pageerror', onError);
  await page.route('**/api/**', async route => {
    const url = new URL(route.request().url());
    let data;
    if (route.request().method() !== 'GET' && url.pathname !== '/api/history') {
      writes.push(url.pathname); return route.fulfill({ status: 403, json: { error: { code: 'OFFLINE_TEST', message: 'Writes disabled' } } });
    }
    if (url.pathname === '/api/auth/state') data = { authenticated: true, user: { mid: 7, name: '离线测试账号', avatar: image } };
    else if (url.pathname.endsWith('/engagement')) data = { liked: false, coins: 0, favorited: false };
    else if (url.pathname === '/api/history') data = { items: [], hasMore: false };
    else if (url.pathname.endsWith('/playback')) data = { cid: Number(url.searchParams.get('cid')), quality: 64, qualities: [{ id: 64, label: '720P' }], duration: 12, mp4Url: `/fixture.mp4?cid=${url.searchParams.get('cid')}`, subtitles: [] };
    else if (url.pathname.endsWith('/subtitles')) data = [];
    else if (url.pathname.endsWith('/comments')) data = { items: [], hasMore: false };
    else if (/^\/api\/videos\/[^/]+$/.test(url.pathname)) data = { bvid: 'BV0000000001', aid: 1, title: '分 P 生命周期回归', description: '离线测试', cover: image, owner: { mid: 7, name: '测试 UP 主', avatar: image }, parts: [1, 2, 3].map(page => ({ cid: 40 + page, page, title: `测试 P${page}`, duration: 12 })), publishedAt: 1, views: 10, interaction: { likes: 1, coins: 2, favorites: 3, coinLimit: 2 } };
    else return route.fulfill({ status: 404, json: { error: { code: 'OFFLINE_TEST', message: url.pathname } } });
    await route.fulfill({ json: data });
  });
  await page.route('**/fixture.mp4?*', route => route.fulfill({ path: 'ios/BilightTests/Fixtures/fullscreen-motion.mp4', contentType: 'video/mp4' }));
  async function check(part) {
    await page.waitForFunction(cid => {
      const video = document.querySelector('video');
      return video?.readyState >= 2 && new URL(video.currentSrc).searchParams.get('cid') === String(cid);
    }, 40 + part);
    const row = { part, actions: await page.locator('.triple-actions').count(), players: await page.locator('.art-video-player').count(), comments: await page.locator('.comments-section').count() };
    rows.push(row);
    if (row.actions !== 1 || row.players !== 1 || row.comments !== 1) throw new Error(`分 P 切换后元素重复: ${JSON.stringify(rows)}`);
  }
  try {
    await page.goto(`${baseURL}/video/BV0000000001`);
    await check(1);
    const actions = await page.locator('.triple-actions').elementHandle();
    for (const part of [2, 3, 1, 2, 3, 1, 3, 2, 1, 2, 3, 1]) {
      await page.getByRole('button', { name: `0${part} 测试 P${part} 0:12`, exact: true }).click();
      await check(part);
      if (!await actions.evaluate(element => element.isConnected && element === document.querySelector('.triple-actions'))) throw new Error('三连栏不应随分 P 重新挂载');
    }
    await page.goBack(); await check(3);
    await page.goForward(); await check(1);
    if (errors.length || writes.length) throw new Error(JSON.stringify({ errors, writes }));
    return { checks: rows.length, rows, errors, writes };
  } catch (error) {
    throw new Error(`${error.message}; ${JSON.stringify({ rows, url: page.url(), media: await page.locator('video').evaluateAll(videos => videos.map(video => ({ src: video.currentSrc, ready: video.readyState }))) })}`);
  } finally {
    page.off('console', onConsole); page.off('pageerror', onError);
    await page.unrouteAll({ behavior: 'wait' });
  }
}
