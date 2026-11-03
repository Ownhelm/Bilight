// Playwright CLI regression: isolated API fixtures, no account and no platform writes.
async page => {
  const base = new URL(page.url()).origin;
  const image = 'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="16" height="9"/%3E';
  const requests = [];
  const owner = { mid: 7, name: '浏览回归 UP', avatar: image, description: '隔离测试' };
  const videos = Array.from({ length: 30 }, (_, i) => ({ bvid: 'BV' + String(i + 1).padStart(10, '0'), aid: i + 1, title: `浏览回归视频 ${i + 1}`, cover: image, duration: 60, publishedAt: 1, owner, views: 1 }));
  await page.route('**/api/**', async route => {
    const request = route.request(), url = new URL(request.url()); requests.push(url.pathname + url.search);
    if (request.method() !== 'GET') throw new Error('Unexpected fixture write');
    const data = url.pathname === '/api/auth/state' ? { authenticated: false }
      : url.pathname === '/api/resolve' ? { path: '/search?keyword=another%20query' }
      : url.pathname === '/api/search' ? { videos, users: [], page: 2, hasMore: false }
      : url.pathname === '/api/creators/7' ? owner
      : url.pathname === '/api/creators/7/videos' ? { items: videos, hasMore: false }
      : url.pathname === '/api/creators/7/collections/season/9' ? { collection: { id: 9, mid: 7, kind: 'season', title: '浏览回归合集', count: 60 }, items: videos, hasMore: false }
      : null;
    if (data) return route.fulfill({ json: data });
    return route.fulfill({ status: 404, json: { error: { code: 'ISOLATED', message: '隔离播放器不提供媒体' } } });
  });
  const results = [];
  try {
    for (const path of ['/search?keyword=fixture&page=2', '/creator/7?page=2', '/creator/7/collections/season/9?page=2']) {
      await page.goto(base + path);
      await page.locator('.video-card').nth(20).waitFor();
      const target = page.locator('.video-card').nth(20).locator('a[href^="/video/"]').first();
      await target.scrollIntoViewIfNeeded();
      const before = await page.evaluate(() => window.scrollY);
      if (before < 300) throw new Error('Fixture did not scroll far enough');
      const endpoint = path.startsWith('/search') ? '/api/search?' : path.includes('/collections/') ? '/api/creators/7/collections/season/9?' : '/api/creators/7/videos?';
      const count = requests.filter(url => url.startsWith(endpoint)).length;
      await target.click(); await page.waitForURL('**/video/**');
      await page.getByText('隔离播放器不提供媒体', { exact: true }).waitFor();
      await page.goBack(); await page.locator('.video-card').nth(20).waitFor();
      await page.waitForTimeout(150);
      const after = await page.evaluate(() => window.scrollY);
      const reads = requests.filter(url => url.startsWith(endpoint)).length;
      results.push({ path, before, after, count, reads });
      if (Math.abs(before - after) > 3 || reads !== count) throw new Error(`Browsing state lost: ${JSON.stringify(results)}`);
      // Returning again must keep the same entry; a new search starts at the top.
      await page.goForward(); await page.getByText('隔离播放器不提供媒体', { exact: true }).waitFor();
      await page.goBack(); await page.locator('.video-card').nth(20).waitFor();
      if (Math.abs(before - await page.evaluate(() => window.scrollY)) > 3) throw new Error('Repeated back/forward lost position');
      const search = page.locator('.header-search input'); await search.fill('another query'); await search.press('Enter');
      await page.waitForURL('**/search?keyword=another%20query'); await page.locator('.video-card').nth(20).waitFor();
      if (await page.evaluate(() => window.scrollY) > 3) throw new Error('A new search inherited an old scroll position');
    }
    return results;
  } finally { await page.unrouteAll({ behavior: 'wait' }); }
}
