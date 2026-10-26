import { readFileSync, mkdirSync, existsSync, chownSync } from 'node:fs';
import { resolve } from 'node:path';
import { BiliHttp } from './transport.js';
import { SecretStore } from './store.js';
import { AuthService } from './auth.js';
import { BiliGateway } from './gateway.js';
import { createApp } from './app.js';

const dataDir = resolve(process.env.DATA_DIR ?? '../Local/data');
const keyFile = resolve(process.env.BILIGHT_KEY_FILE ?? '../Local/secrets/master-key');
if (!existsSync(keyFile)) { console.error('缺少会话加密密钥，请先运行 npm run setup。'); process.exit(1); }
const key = readFileSync(keyFile);
if (key.length !== 32) { console.error('会话加密密钥必须是 32 字节。'); process.exit(1); }
mkdirSync(dataDir, { recursive: true, mode: 0o700 });
// Read the owner-only Docker secret before dropping the startup user's privileges.
if (process.env.BILIGHT_DROP_PRIVILEGES === '1' && process.getuid?.() === 0) {
  chownSync(dataDir, 1000, 1000);
  process.setgid!(1000);
  process.setuid!(1000);
}
const store = new SecretStore(resolve(dataDir, 'bilight.sqlite'), key);
const http = new BiliHttp();
const auth = new AuthService(http, store);
await auth.init();
const gateway = new BiliGateway(http);
const app = await createApp({ auth, gateway, key });
const port = Number(process.env.PORT ?? 3880);
await app.listen({ port, host: process.env.HOST ?? '127.0.0.1' });
console.info(`Bilight 已启动：http://127.0.0.1:${port}`);
let closing = false;
const shutdown = async () => { if (closing) return; closing = true; await app.close(); await auth.close(); store.close(); process.exit(0); };
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
