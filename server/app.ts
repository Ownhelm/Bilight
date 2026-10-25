import Fastify from 'fastify';
import cookie from '@fastify/cookie';
import fastifyStatic from '@fastify/static';
import { randomBytes } from 'node:crypto';
import { Readable } from 'node:stream';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import type { AuthService } from './auth.js';
import type { BiliGateway } from './gateway.js';
import { MediaRegistry } from './media.js';
import type { SmsSend, User, VideoSummary, Comment, EngagementAction, WatchProgress } from '../shared/types.js';

export interface AppOptions { auth: AuthService; gateway: BiliGateway; key: Buffer; media?: MediaRegistry; staticDir?: string; allowedOrigins?: string[] }
const fail = (code: string, message: string, status = 400) => Object.assign(new Error(message), { code, status });
const text = (value: unknown, max = 200) => typeof value === 'string' && value.length <= max ? value : '';
const number = (value: unknown, fallback = 1) => Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : fallback;
const bvidOf = (value: unknown) => { if (!/^BV[0-9A-Za-z]{10}$/.test(String(value))) throw fail('INVALID_VIDEO', '视频 BV 号不正确。'); return String(value); };

export async function createApp(options: AppOptions) {
  const { auth, gateway } = options;
  const media = options.media ?? new MediaRegistry(gateway);
  let historyGeneration = 0, historySequence = 0;
  let historyWrites: Promise<unknown> = Promise.resolve();
  const latestHistory = new Map<string, number>();
  const app = Fastify({ logger: { level: 'warn', redact: ['req.headers.cookie', 'req.headers.authorization', 'res.headers.set-cookie'] }, disableRequestLogging: true, bodyLimit: 16384, trustProxy: false });
  const origins = new Set(options.allowedOrigins ?? ['http://127.0.0.1:3880', 'http://localhost:3880', 'http://bilibili.local', 'https://bilibili.local', ...(process.env.NODE_ENV !== 'production' ? ['http://127.0.0.1:5173', 'http://localhost:5173'] : [])]);
  const hosts = new Set([...origins].map(origin => new URL(origin).host));
  const limits = new Map<string, number[]>();
  await app.register(cookie, { secret: options.key.toString('hex') });

  app.addHook('onRequest', async (request, reply) => {
    if (!hosts.has(request.headers.host ?? '')) throw fail('INVALID_HOST', '请通过本机 Bilight 地址访问。', 403);
    reply.header('X-Content-Type-Options', 'nosniff').header('Referrer-Policy', 'no-referrer').header('X-Frame-Options', 'DENY');
    reply.header('Content-Security-Policy', "default-src 'self'; script-src 'self' https://*.geetest.com https://*.geetest.cn https://*.geevisit.com https://*.gsensebot.com; style-src 'self' 'unsafe-inline' https://*.geetest.com https://*.geetest.cn https://*.geevisit.com https://*.gsensebot.com; img-src 'self' data: blob: https://*.geetest.com https://*.geetest.cn https://*.geevisit.com https://*.gsensebot.com; connect-src 'self' https://*.geetest.com https://*.geetest.cn https://*.geevisit.com https://*.gsensebot.com; media-src 'self' blob:; worker-src 'self' blob:; font-src 'self' data:; frame-src https://*.geetest.com https://*.geetest.cn https://*.geevisit.com https://*.gsensebot.com; object-src 'none'; base-uri 'self'; frame-ancestors 'none'");
    const route = request.routeOptions.url ?? request.url;
    const isApi = route.startsWith('/api/');
    if (isApi) reply.header('Cache-Control', 'no-store');
    const token = request.cookies.bilight_session;
    const valid = !!token && request.unsignCookie(token).valid;
    if (['POST', 'PUT', 'DELETE', 'PATCH'].includes(request.method)) {
      if (!valid || !origins.has(request.headers.origin ?? '') || request.headers['x-bilight-request'] !== '1') throw fail('INVALID_ORIGIN', '请刷新 Bilight 页面后重试。', 403);
      if (route.startsWith('/api/auth/') || /\/(triple|interaction|favorite-folders)$/.test(route)) {
        const key = route;
        const now = Date.now();
        const attempts = (limits.get(key) ?? []).filter(at => now - at < 60000);
        const max = key === '/api/auth/sms/send' ? 2 : /\/(triple|interaction|favorite-folders)$/.test(key) ? 10 : 20;
        if (attempts.length >= max) throw fail('TOO_MANY_REQUESTS', '操作过于频繁，请稍后再试。', 429);
        attempts.push(now); limits.set(key, attempts);
      }
    } else if (isApi && !valid) {
      reply.setCookie('bilight_session', randomBytes(24).toString('hex'), { signed: true, httpOnly: true, sameSite: 'strict', path: '/', maxAge: 60 * 60 * 24 * 365 });
    }
  });

  app.setErrorHandler((error, _request, reply) => {
    const err = error as Error & { status?: number; statusCode?: number; code?: string | number };
    const numericCode = String(err.code ?? '');
    const candidate = err.status ?? err.statusCode ?? 500;
    const status = numericCode === '-101' ? 401 : ['-412', '-352'].includes(numericCode) ? 429 : candidate >= 400 && candidate <= 599 ? candidate : 500;
    const message = status === 500 ? '服务暂时无法完成请求，请稍后重试。' : String(err.message || '请求未完成。').replace(/https?:\/\/[^\s]+/g, '[链接]').slice(0, 240);
    if (status === 500) app.log.error({ code: 'INTERNAL_ERROR', name: err.name }, 'Bilight request failed');
    reply.code(status).send({ error: { code: numericCode || 'INTERNAL_ERROR', message, retryable: status >= 500 || status === 429 } });
  });

  const userImage = <T extends User>(user: T): T => ({ ...user, avatar: media.image(user.avatar) });
  const videoImages = <T extends VideoSummary>(video: T): T => ({ ...video, cover: media.image(video.cover), owner: userImage(video.owner) });
  const commentImages = (comment: Comment): Comment => ({ ...comment, user: userImage(comment.user), replies: comment.replies.map(commentImages) });
  const requireLogin = async () => { if (!(await auth.state()).authenticated) throw fail('LOGIN_REQUIRED', '登录 B 站后即可使用此功能。', 401); };

  app.get('/health', async () => ({ ok: true, service: 'bilight' }));
  app.get('/api/auth/state', async () => { const state = await auth.state(); return { ...state, ...(state.user ? { user: userImage(state.user) } : {}) }; });
  app.post('/api/auth/qr', async () => auth.qrCreate());
  app.get<{ Params: { id: string } }>('/api/auth/qr/:id', async request => auth.qrPoll(text(request.params.id, 80)));
  app.get('/api/auth/countries', async () => auth.countries());
  app.post('/api/auth/captcha', async () => auth.captcha());
  app.post<{ Body: SmsSend }>('/api/auth/sms/send', async request => {
    const input = request.body;
    if (!input || !/^\d{5,18}$/.test(input.tel ?? '') || !Number.isSafeInteger(input.cid) || !text(input.challengeId, 80) || !text(input.challenge, 200) || !text(input.validate, 200) || !text(input.seccode, 240)) throw fail('INVALID_SMS', '请填写正确的手机号并完成人机验证。');
    return auth.sendSms(input);
  });
  app.post<{ Body: { id: string; code: string } }>('/api/auth/sms/login', async request => {
    if (!text(request.body?.id, 80) || !/^\d{4,8}$/.test(request.body?.code ?? '')) throw fail('INVALID_SMS_CODE', '请填写正确的短信验证码。');
    return auth.loginSms(request.body);
  });
  app.post('/api/auth/logout', async () => { historyGeneration++; latestHistory.clear(); await auth.logout(); media.clear(); return { ok: true }; });

  app.get<{ Querystring: { input?: string } }>('/api/resolve', async request => {
    const input = text(request.query.input, 2048).trim();
    if (!input) throw fail('EMPTY_SEARCH', '输入关键词、BV 号或视频链接。');
    return { path: await gateway.resolve(input) };
  });
  app.get<{ Querystring: { keyword?: string; type?: string; page?: string } }>('/api/search', async request => {
    const keyword = text(request.query.keyword, 200).trim();
    if (!keyword) throw fail('EMPTY_SEARCH', '请输入搜索关键词。');
    const type = request.query.type === 'user' ? 'user' : 'video';
    const result = await gateway.search(keyword, type, Math.min(100, number(request.query.page)));
    return { ...result, videos: result.videos.map(videoImages), users: result.users.map(userImage) };
  });
  app.get<{ Querystring: { cursor?: string } }>('/api/following', async request => {
    await requireLogin();
    const result = await gateway.following(text(request.query.cursor, 1024) || undefined);
    return { ...result, items: result.items.map(videoImages) };
  });
  app.get<{ Querystring: { cursor?: string; limit?: string; source?: string } }>('/api/history', async request => {
    await requireLogin();
    const cursor = request.query.cursor;
    if (cursor !== undefined && (!text(cursor, 600) || !/^[\w-]+$/.test(cursor))) throw fail('INVALID_CURSOR', '历史记录分页标识无效。');
    if (request.query.source && request.query.source !== 'bilibili') throw fail('INVALID_SOURCE', '历史记录已统一到 B 站，请刷新页面。');
    const result = await gateway.history(cursor, Math.min(20, number(request.query.limit, 20)));
    return { ...result, items: result.items.map(videoImages) };
  });
  app.post<{ Body: WatchProgress }>('/api/history', async request => {
    const sequence = ++historySequence;
    const generation = historyGeneration, state = await auth.state();
    if (!state.authenticated || !state.user) throw fail('LOGIN_REQUIRED', '登录 B 站后即可保存观看记录。', 401);
    const input = request.body;
    if (!input || input.accountMid !== state.user.mid) throw fail('ACCOUNT_CHANGED', '账号已变化，未保存旧账号的观看记录。', 409);
    if (!Number.isSafeInteger(input.cid) || input.cid <= 0 || typeof input.progress !== 'number' || !Number.isFinite(input.progress) || input.progress < 0 || input.progress > 7 * 86400 || (input.completed !== undefined && typeof input.completed !== 'boolean')) throw fail('INVALID_PROGRESS', '观看进度不正确。');
    const video = await gateway.video(bvidOf(input.bvid)), part = video.parts.find(item => item.cid === input.cid);
    if (!part) throw fail('INVALID_PART', '这个分 P 不属于当前视频。');
    const current = await auth.state();
    if (generation !== historyGeneration || !current.authenticated || current.user?.mid !== state.user.mid) throw fail('ACCOUNT_CHANGED', '账号已变化，未保存旧账号的观看记录。', 409);
    const key = `${state.user.mid}:${video.bvid}`;
    latestHistory.set(key, Math.max(sequence, latestHistory.get(key) ?? 0));
    const write = historyWrites.catch(() => {}).then(async () => {
      const active = await auth.state();
      if (generation !== historyGeneration || !active.authenticated || active.user?.mid !== state.user!.mid) throw fail('ACCOUNT_CHANGED', '账号已变化，未同步旧账号的观看记录。', 409);
      if ((latestHistory.get(key) ?? sequence) > sequence) return { ok: true, superseded: true };
      await gateway.reportHistory(video, part, input.progress);
      return { ok: true };
    });
    historyWrites = write;
    return write;
  });
  app.get<{ Params: { mid: string }; Querystring: { page?: string } }>('/api/creators/:mid/collections', async request => {
    const result = await gateway.creatorCollections(number(request.params.mid, 0), Math.min(1000, number(request.query.page)));
    return { ...result, items: result.items.map(item => ({ ...item, cover: media.image(item.cover) })) };
  });
  app.get<{ Params: { mid: string; kind: string; id: string }; Querystring: { page?: string } }>('/api/creators/:mid/collections/:kind/:id', async request => {
    const kind = request.params.kind;
    if (kind !== 'season' && kind !== 'series') throw fail('INVALID_COLLECTION', '合集或列表类型不正确。');
    const result = await gateway.collection(number(request.params.mid, 0), kind, number(request.params.id, 0), Math.min(1000, number(request.query.page)));
    return { ...result, collection: { ...result.collection, cover: media.image(result.collection.cover) }, items: result.items.map(videoImages) };
  });
  app.get<{ Params: { mid: string } }>('/api/creators/:mid', async request => userImage(await gateway.creator(number(request.params.mid, 0))));
  app.get<{ Params: { mid: string }; Querystring: { page?: string } }>('/api/creators/:mid/videos', async request => {
    const result = await gateway.creatorVideos(number(request.params.mid, 0), Math.min(100, number(request.query.page)));
    return { ...result, items: result.items.map(videoImages) };
  });
  app.get<{ Params: { bvid: string } }>('/api/videos/:bvid', async request => {
    const detail = await gateway.video(bvidOf(request.params.bvid));
    return { ...detail, cover: media.image(detail.cover), owner: userImage(detail.owner) };
  });
  app.get<{ Params: { bvid: string } }>('/api/videos/:bvid/engagement', async request => {
    await requireLogin(); return gateway.engagement(bvidOf(request.params.bvid));
  });
  app.post<{ Params: { bvid: string } }>('/api/videos/:bvid/triple', async request => {
    await requireLogin(); return gateway.triple(bvidOf(request.params.bvid));
  });
  app.get<{ Params: { bvid: string } }>('/api/videos/:bvid/favorite-folders', async request => {
    await requireLogin(); return { items: await gateway.favoriteFolders(bvidOf(request.params.bvid)) };
  });
  app.post<{ Params: { bvid: string }; Body: { title: string } }>('/api/videos/:bvid/favorite-folders', async request => {
    await requireLogin(); return gateway.createFavoriteFolder(bvidOf(request.params.bvid), text(request.body?.title, 20));
  });
  app.get<{ Params: { bvid: string } }>('/api/videos/:bvid/coin-info', async request => {
    await requireLogin(); return gateway.coinInfo(bvidOf(request.params.bvid));
  });
  app.get<{ Params: { bvid: string } }>('/api/videos/:bvid/coin-experience', async request => {
    bvidOf(request.params.bvid); await requireLogin(); return { experience: await gateway.coinExperience() };
  });
  app.post<{ Params: { bvid: string }; Body: EngagementAction }>('/api/videos/:bvid/interaction', async request => {
    await requireLogin(); return gateway.interact(bvidOf(request.params.bvid), request.body);
  });
  app.get<{ Params: { bvid: string }; Querystring: { cid?: string; quality?: string } }>('/api/videos/:bvid/playback', async request => {
    const bvid = bvidOf(request.params.bvid);
    const detail = await gateway.video(bvid);
    const cid = number(request.query.cid, detail.parts[0]?.cid ?? 0);
    if (!detail.parts.some(part => part.cid === cid)) throw fail('INVALID_PART', '该分 P 不属于当前视频。');
    const source = await gateway.playback(bvid, cid, number(request.query.quality, 127));
    return media.playback(source, bvid);
  });
  app.get<{ Params: { bvid: string }; Querystring: { cid?: string } }>('/api/videos/:bvid/danmaku', async request => {
    const detail = await gateway.video(bvidOf(request.params.bvid));
    const cid = number(request.query.cid, detail.parts[0]?.cid ?? 0);
    if (!detail.parts.some(part => part.cid === cid)) throw fail('INVALID_PART', '该分 P 不属于当前视频。');
    return gateway.danmaku(cid);
  });
  app.get<{ Params: { bvid: string }; Querystring: { page?: string; cursor?: string } }>('/api/videos/:bvid/comments', async request => {
    const detail = await gateway.video(bvidOf(request.params.bvid));
    const result = await gateway.comments(detail.aid, Math.min(1000, number(request.query.page)), text(request.query.cursor, 4096) || undefined);
    return { ...result, items: result.items.map(commentImages) };
  });

  app.get<{ Params: { id: string } }>('/api/media/:id/manifest.mpd', async (request, reply) => {
    const manifest = media.manifest(request.params.id);
    if (!manifest) throw fail('MEDIA_EXPIRED', '播放信息已过期，请重新打开视频。', 404);
    return reply.type('application/dash+xml').send(manifest);
  });
  app.get<{ Params: { id: string } }>('/api/media/:id/subtitle.vtt', async (request, reply) => {
    const subtitle = await media.subtitle(request.params.id);
    if (!subtitle) throw fail('MEDIA_EXPIRED', '字幕信息已过期，请重新打开视频。', 404);
    return reply.type('text/vtt; charset=utf-8').send(subtitle);
  });
  app.route<{ Params: { id: string } }>({ method: ['GET', 'HEAD'], url: '/api/media/:id', handler: async (request, reply) => {
    const controller = new AbortController();
    reply.raw.on('close', () => controller.abort());
    const result = await media.fetch(request.params.id, request.headers.range, request.method === 'HEAD', controller.signal);
    if (!result) throw fail('MEDIA_EXPIRED', '资源已过期，请刷新页面。', 404);
    const { response, kind } = result;
    if (!response.ok && response.status !== 416) { await response.body?.cancel(); throw fail('MEDIA_UNAVAILABLE', 'B 站媒体暂时无法加载，请稍后重试。', 502); }
    const upstreamType = (response.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
    // The avatar CDN uses image/jpg for JPEGs; expose its standard MIME type locally.
    const contentType = kind === 'image' && upstreamType === 'image/jpg' ? 'image/jpeg' : upstreamType;
    const safeMedia = ['video/mp4', 'audio/mp4', 'audio/x-m4a', 'video/x-m4v', 'application/mp4', 'application/octet-stream'];
    if ((kind === 'video' || kind === 'audio') && response.status !== 416 && !safeMedia.includes(contentType)) { await response.body?.cancel(); throw fail('INVALID_MEDIA', '媒体返回了不支持的格式，请重新加载视频。', 502); }
    if (kind === 'subtitle') { await response.body?.cancel(); throw fail('NOT_FOUND', '请通过字幕入口读取字幕。', 404); }
    reply.code(response.status);
    for (const name of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'etag', 'last-modified']) {
      const value = response.headers.get(name); if (value) reply.header(name, value);
    }
    if (kind === 'image') {
      if (!['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif', 'image/bmp'].includes(contentType)) { await response.body?.cancel(); throw fail('INVALID_IMAGE', '图片格式不受支持。', 502); }
      reply.type(contentType);
      reply.header('Cache-Control', 'private, max-age=3600');
    }
    if (kind === 'video' || kind === 'audio') reply.type(kind === 'video' ? 'video/mp4' : 'audio/mp4');
    if (request.method === 'HEAD' || !response.body || response.status === 416) { await response.body?.cancel(); if (request.method !== 'HEAD') reply.removeHeader('content-length'); return reply.send(); }
    return reply.send(Readable.fromWeb(response.body as import('node:stream/web').ReadableStream));
  } });

  const staticDir = options.staticDir ?? resolve('dist');
  if (existsSync(resolve(staticDir, 'index.html'))) {
    await app.register(fastifyStatic, { root: staticDir, prefix: '/', index: false, wildcard: false, dotfiles: 'deny' });
    app.setNotFoundHandler(async (request, reply) => {
      if (request.url.startsWith('/api/') || !['GET', 'HEAD'].includes(request.method)) return reply.code(404).send({ error: { code: 'NOT_FOUND', message: '没有这个接口。' } });
      return reply.type('text/html').header('Cache-Control', 'no-cache').sendFile('index.html');
    });
  }
  return app;
}
