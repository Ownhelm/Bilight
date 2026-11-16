// Run through Playwright CLI's run-code against a local frontend. Every API request is intercepted.
async page => {
  const baseURL = new URL(page.url()).origin;
  const route = '/api/videos/BV0000000001/comments';
  const otherVideoRoute = '/api/videos/BV0000000002/comments';
  const dynamicRoute = '/api/dynamics/123/comments';
  const image = 'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/%3E';
  const viewer = { mid: 7, name: '测试账号', avatar: image };
  const owner = { mid: 8, name: '视频作者', avatar: image };
  const mention = { mid: 9, name: '相机用户', avatar: image };
  const emotes = { '[惊喜]': '/api/media/comment-emote', '[坏图]': '/api/media/missing-emote' };
  const root = { id: '101', user: owner, text: '主评论 😀 [惊喜] [坏图] @视频作者 [未知表情]', createdAt: 1, likes: 10000, liked: false, replyCount: 1, replies: [], mentions: [owner], emotes };
  const existingReply = { ...root, id: '102', text: '之前的楼中楼回复 [惊喜]', replyCount: 0 };
  const dynamicComment = { ...root, id: '201', text: '动态自己的评论', likes: 0, replyCount: 0 };
  const writes = [], queries = [], releases = [];
  let rejectLike = true, guest = false, postedReply;

  function check(condition, message) {
    if (!condition) throw new Error(message);
  }

  await page.route('**/api/**', async request => {
    const url = new URL(request.request().url());
    const path = url.pathname;
    const method = request.request().method();
    const ok = json => request.fulfill({ json });
    const fail = (status, code, message) => request.fulfill({ status, json: { error: { code, message } } });
    if (method === 'POST') {
      if (path === '/api/history') return ok({});
      const body = request.request().postDataJSON();
      writes.push({ path, body });
      if (path === route + '/101/like' || path === route + '/102/like') {
        await new Promise(resolve => releases.push(resolve));
        if (path.endsWith('/102/like')) return ok({ liked: body.liked, likes: body.liked ? 10005 : 10004 });
        return rejectLike ? fail(503, 'LIKE_UNAVAILABLE', '点赞暂未确认') : ok({ liked: body.liked, likes: body.liked ? 10002 : 10000 });
      }
      if (path === route || path === dynamicRoute) {
        if (body.text === '保留这段草稿') return fail(400, 'INVALID_INPUT', '评论未发布');
        const value = { id: body.root ? '103' : '104', user: viewer, text: body.text, createdAt: 2, likes: 0, liked: false, replies: [], mentions: body.mentions };
        if (body.root) postedReply = value;
        return ok(value);
      }
      if (path === dynamicRoute + '/201/like') return ok({ liked: body.liked, likes: 1 });
      return fail(403, 'FIXTURE_WRITE_DISABLED', '模拟环境已拦截未登记的写入');
    }
    if (path === '/api/auth/state') return ok(guest ? { authenticated: false } : { authenticated: true, user: viewer });
    if (path === '/api/history') return ok({ items: [], hasMore: false });
    if (path === '/api/media/comment-emote') return request.fulfill({ contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><circle cx="10" cy="10" r="9" fill="orange" /></svg>' });
    if (path === '/api/dynamics/123') return ok({ id: '123', author: owner, action: '投稿', publishedAt: 1, text: '视频动态', comments: 5, likes: 0, liked: false,
      video: { bvid: 'BV0000000001', aid: 1, title: '视频动态所附视频', cover: image, owner, duration: 5, publishedAt: 1, views: 10 } });
    if (path.endsWith('/engagement')) return ok({ liked: false, coins: 0, favorited: false });
    if (path === route || path === otherVideoRoute) return ok({ items: [root], hasMore: false });
    if (path === dynamicRoute) return ok({ items: [dynamicComment], hasMore: false });
    if (path === dynamicRoute + '/201/replies') return ok({ items: postedReply ? [postedReply] : [], total: postedReply ? 1 : 0, hasMore: false });
    if (path === route + '/101/replies') return ok(url.searchParams.get('page') === '2'
      ? { items: postedReply ? [postedReply] : [], total: 2, hasMore: false }
      : { items: [existingReply], total: 1, hasMore: true });
    if (path === route + '/mention-users' || path === dynamicRoute + '/mention-users') { queries.push(url.searchParams.get('q')); return ok({ items: [mention] }); }
    if (path === '/api/videos/BV0000000001' || path === '/api/videos/BV0000000002') return ok({
      bvid: path.split('/').at(-1), aid: 1, title: '隔离评论回归', description: '简介回归内容', cover: image, owner,
      parts: [{ cid: 2, page: 1, title: '测试', duration: 5 }], publishedAt: 1, views: 10, interaction: { likes: 1, coins: 2, favorites: 3, coinLimit: 2 },
    });
    return fail(404, 'OFFLINE_TEST', path);
  });

  try {
    await page.evaluate(() => {
      localStorage.removeItem('bilight:video-comments-expanded');
      localStorage.removeItem('bilight:video-description-expanded');
    });
    await page.setViewportSize({ width: 320, height: 760 });
    await page.goto(`${baseURL}/video/BV0000000001`);
    const testComment = page.locator('article.comment:not(.comment-reply)').filter({ hasText: '主评论' });
    await testComment.waitFor();
    const emoteImage = testComment.getByRole('img', { name: '[惊喜]' });
    await emoteImage.waitFor();
    await page.waitForFunction(() => document.querySelector('.comment-emote[alt="[惊喜]"]')?.naturalWidth > 0);
    await testComment.getByRole('img', { name: '[坏图]' }).waitFor({ state: 'detached' });
    const rootText = testComment.locator('.comment-body > p').first();
    check(await testComment.getByRole('link', { name: '@视频作者' }).getAttribute('href') === '/creator/8', '自定义表情与真实 UID 的提及应能同时呈现');
    const text = await rootText.textContent();
    check(['😀', '[坏图]', '[未知表情]'].every(token => text.includes(token)), 'Unicode 表情、坏图与未知标记应保留为文字');
    const like = testComment.locator('.comment-like').first();
    const pending = like.locator('span');
    async function awaitPendingWrite() {
      const deadline = Date.now() + 4000;
      while (!releases.length && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
      check(releases.length === 1, '同一条评论同时只处理一次点赞请求');
      return releases.shift();
    }
    async function toggle(expectedPending, expectedFinal) {
      await like.click();
      await page.waitForFunction(expected => document.querySelector('.comment-like[aria-busy="true"]')?.textContent === expected, expectedPending);
      check(await pending.textContent() === expectedPending, '点赞计数应在提交时立即更新');
      (await awaitPendingWrite())();
      await page.waitForFunction(expected => document.querySelector('.comment-like')?.getAttribute('aria-busy') === 'false' && document.querySelector('.comment-like')?.textContent === expected, expectedFinal);
    }
    await like.click();
    check(await pending.textContent() === '10,001', '连点第一下立即加一');
    await like.click();
    check(await pending.textContent() === '10,000', '等待期间可继续点并立即减一');
    await page.waitForFunction(() => document.querySelector('.comment-like')?.getAttribute('aria-busy') === 'false');
    check(writes.length === 0, '同一批点赞和取消应相互抵消');
    await toggle('10,001', '10,000');
    await testComment.getByRole('alert').filter({ hasText: '点赞暂未确认' }).waitFor();
    rejectLike = false;
    await toggle('10,001', '10,002');
    await toggle('10,001', '10,000');

    const composer = page.locator('form.comment-composer').first();
    const field = composer.getByRole('textbox', { name: '写评论' });
    check(!await composer.getByRole('button', { name: '@ 用户', exact: true }).count(), '评论输入框不应另放 @ 按钮');
    await field.fill('name@example');
    check(!await composer.getByRole('group', { name: '@ 用户建议' }).count(), '邮件地址不应打开提及候选');
    await field.fill('保留这段草稿');
    await composer.getByRole('button', { name: '发布', exact: true }).click();
    await composer.getByRole('alert').filter({ hasText: '评论未发布' }).waitFor();
    check(await field.inputValue() === '保留这段草稿', '失败后应保留草稿');
    await field.fill('');
    await field.press('@');
    await composer.getByRole('button', { name: '相机用户' }).waitFor();
    await field.fill('谢谢 @相机分享');
    await field.press('ArrowLeft'); await field.press('ArrowLeft');
    await page.waitForFunction(() => document.querySelector('.comment-mention-results')?.textContent.includes('相机用户'));
    await composer.getByRole('button', { name: '相机用户' }).click();
    check(await field.inputValue() === '谢谢 @相机用户 分享', '选择用户应替换光标前的 @ 片段并保留后文');
    await composer.getByRole('button', { name: '发布', exact: true }).click();
    const linked = page.getByRole('link', { name: '@相机用户', exact: true });
    await linked.waitFor();
    check(await linked.getAttribute('href') === '/creator/9' && await field.inputValue() === '', '发布成功应以真实用户 ID 渲染并清空草稿');

    await testComment.getByRole('button', { name: '展开', exact: true }).click();
    const reply = page.locator('.comment-reply').filter({ hasText: '之前的楼中楼回复' });
    const replyLike = reply.locator('button.comment-like');
    await replyLike.click();
    check(await replyLike.textContent() === '10,001', '楼中楼应立即加一');
    const releaseFirst = await awaitPendingWrite();
    await replyLike.click();
    check(await replyLike.textContent() === '10,000', '楼中楼请求已发出时也可以取消');
    releaseFirst();
    const releaseSecond = await awaitPendingWrite();
    check(await replyLike.textContent() === '10,000', '首笔返回的旧总数不能覆盖楼中楼最后一次点击');
    releaseSecond();
    await page.waitForFunction(() => document.querySelector('.comment-reply .comment-like')?.textContent === '10,004');
    check(writes.filter(write => write.path === route + '/102/like').map(write => write.body.liked).join(',') === 'true,false', '楼中楼应串行同步同一评论下最新状态');
    await reply.getByRole('button', { name: '回复', exact: true }).click();
    const replyForm = reply.locator('form.comment-composer');
    const replyField = replyForm.getByRole('textbox');
    check(await replyField.inputValue() === '' && !await replyForm.getByRole('group', { name: '@ 用户建议' }).count(), '打开楼中楼回复不能预填 @ 或弹出候选');
    await replyField.dispatchEvent('compositionstart');
    await page.keyboard.insertText('新的楼中楼回复 ＠相');
    check(!await replyForm.getByRole('group', { name: '@ 用户建议' }).count(), '输入法组字未确认时不应打开提及候选');
    await replyField.dispatchEvent('compositionend', { data: '相' });
    await replyForm.getByRole('button', { name: '相机用户' }).click();
    check(await replyField.inputValue() === '新的楼中楼回复 @相机用户 ', '楼中楼确认全角 ＠ 后应能选人');
    check(await replyForm.evaluate(form => form.scrollWidth <= form.clientWidth), '窄屏的回复输入框必须留在评论区内');
    await replyForm.getByRole('button', { name: '回复', exact: true }).click();
    const postedNested = testComment.locator('.comment-reply').filter({ hasText: '新的楼中楼回复' });
    await postedNested.waitFor();
    await testComment.getByRole('button', { name: '加载更多', exact: true }).click();
    await testComment.getByRole('button', { name: '加载更多', exact: true }).waitFor({ state: 'hidden' });
    check(await postedNested.count() === 1, '分页合并应去重');
    check(queries.includes('') && queries.includes('相机'), '应访问官方最近候选与关键字搜索两种读取');
    const top = writes.find(write => write.body.text === '谢谢 @相机用户 分享');
    check(top?.body.mentions[0]?.mid === 9 && top?.body.mentions[0]?.name === '相机用户' && !top?.body.root, '发布应发送已选择的用户 ID');
    const nested = writes.find(write => write.body.text === '新的楼中楼回复 @相机用户');
    check(nested?.body.root === '101' && nested?.body.parent === '102' && nested?.body.mentions[0]?.mid === 9, '楼中楼回复须携带真实根评论、回复目标和提及用户');

    await page.goto(`${baseURL}/dynamic/123`);
    await page.getByRole('link', { name: '查看评论，共5条' }).click();
    const dynamicComments = page.locator('#dynamic-comments');
    await dynamicComments.getByText('动态自己的评论', { exact: true }).waitFor();
    check(!await dynamicComments.getByText('主评论', { exact: false }).count(), '动态详情应当显示动态自己的评论');
    await dynamicComments.getByRole('button', { name: '点赞评论' }).click();
    await dynamicComments.getByRole('button', { name: '取消评论点赞' }).waitFor();
    await dynamicComments.locator('.comment-like[aria-busy="false"]').waitFor();
    await dynamicComments.getByRole('button', { name: '回复', exact: true }).click();
    const dynamicReply = dynamicComments.locator('form.comment-composer').last();
    await dynamicReply.getByRole('textbox').fill('从动态回复 @相机');
    await dynamicReply.getByRole('button', { name: '相机用户' }).click();
    await dynamicReply.getByRole('button', { name: '回复', exact: true }).click();
    await dynamicComments.getByText('从动态回复', { exact: false }).waitFor();
    const fromDynamic = writes.find(write => write.body.text === '从动态回复 @相机用户');
    check(fromDynamic?.path === dynamicRoute && fromDynamic?.body.root === '201' && fromDynamic?.body.mentions[0]?.mid === 9, '回复应指向动态评论和真实的提及用户');
    check(writes.length === 10 && writes.every(write => write.body.accountMid === 7), '写请求必须属于当前账号');

    const expansion = page.locator('.comments-trigger');
    const descriptionTitle = page.locator('.video-description summary');
    const description = page.getByText('简介回归内容', { exact: true });
    await page.goto(`${baseURL}/video/BV0000000001`);
    await descriptionTitle.waitFor();
    check(!await description.isVisible(), '简介首次默认收起');
    for (const width of [320, 1200]) {
      await page.setViewportSize({ width, height: 760 });
      const size = await descriptionTitle.evaluate(title => getComputedStyle(title).fontSize);
      check(size === await expansion.locator('span').first().evaluate(title => getComputedStyle(title).fontSize), '简介和评论标题字号应一致');
    }
    await descriptionTitle.press('Enter');
    await description.waitFor();
    check(await expansion.getAttribute('aria-expanded') === 'true', '展开简介不应改变评论状态');
    await expansion.click();
    await page.goto(`${baseURL}/video/BV0000000002`);
    await description.waitFor();
    check(await expansion.getAttribute('aria-expanded') === 'false', '切换另一条视频应保持评论区收起');
    await page.reload();
    await description.waitFor();
    check(await expansion.getAttribute('aria-expanded') === 'false', '重新载入应保持最后的收起选择');
    await descriptionTitle.click();
    await description.waitFor({ state: 'hidden' });
    check(await expansion.getAttribute('aria-expanded') === 'false', '收起简介不应改变评论状态');
    await expansion.click();
    await page.goto(`${baseURL}/video/BV0000000001`);
    await descriptionTitle.waitFor();
    check(!await description.isVisible(), '切换视频后简介应保持收起');
    check(await expansion.getAttribute('aria-expanded') === 'true', '重新展开应应用到所有视频评论区');

    guest = true;
    await page.reload();
    const login = page.locator('.comment-composer-guest').getByRole('button', { name: '登录' });
    await login.waitFor();
    check(!await page.getByRole('textbox', { name: '写评论' }).count() && writes.length === 10, '游客只能查看评论和登录入口');
    return { writes: writes.length, mentionQueries: queries.length };
  } finally {
    for (const release of releases) release();
    await page.unroute('**/api/**');
  }
}
