import Fastify from 'fastify';
import staticFiles from '@fastify/static';
import { resolve } from 'node:path';
import { existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { account, people, videos, collections, history, page } from './demo-fixtures.mjs';

// A separate loopback-only server: no gateway, credentials, database or upstream fetches.
export async function createDemo({ assetsDir = resolve(process.env.BILIGHT_DEMO_ASSETS_DIR ?? '../Promotion/DemoAssets') } = {}) {
  const app = Fastify({ logger: false });
  app.addHook('onRequest', async (request, reply) => {
    reply.header('Content-Security-Policy', "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; font-src 'self'; media-src 'self' blob:; frame-src 'none'");
    if (!['GET', 'HEAD'].includes(request.method)) return reply.code(403).send({ error: { code: 'DEMO_READ_ONLY', message: '这是离线演示，无法提交账号操作。' } });
  });
  await app.register(staticFiles, { root: resolve('dist'), wildcard: false });
  if (existsSync(assetsDir)) {
    await app.register(staticFiles, { root: assetsDir, prefix: '/demo-assets/', decorateReply: false });
  } else {
    app.get('/demo-assets/*', async (_request, reply) => reply.code(503).send({ error: { code: 'DEMO_ASSETS_MISSING', message: '未配置外部演示素材目录。' } }));
  }
  app.get('/api/auth/state', async () => ({ authenticated: true, user: account }));
  app.get('/api/following', async () => page(videos));
  app.get('/api/history', async request => page(history.slice(0, Number(request.query.limit) || 20)));
  app.get('/api/search', async request => ({ videos, users: people, hasMore: false, page: 1, keyword: request.query.keyword ?? '', type: request.query.type ?? 'video' }));
  app.get('/api/creators/:mid', async (request, reply) => people.find(x => x.mid === Number(request.params.mid)) ?? reply.code(404).send({ error: { code: 'DEMO_ONLY', message: '此 UP 主未纳入离线预览。' } }));
  app.get('/api/creators/:mid/videos', async request => page(videos.filter(video => video.owner.mid === Number(request.params.mid))));
  app.get('/api/creators/:mid/collections', async request => page(collections.filter(group => group.mid === Number(request.params.mid))));
  app.setNotFoundHandler(async (request, reply) => {
    if (request.url.startsWith('/api/')) return reply.code(404).send({ error: { code: 'DEMO_ONLY', message: '此操作未纳入离线演示。' } });
    return reply.sendFile('index.html');
  });
  return app;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const app = await createDemo();
  await app.listen({ host: '127.0.0.1', port: 3881 });
  console.info('Bilight 离线 mock 预览：http://127.0.0.1:3881（不连接 B 站）');
}
