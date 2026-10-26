import { randomBytes } from 'node:crypto';
import { mkdirSync, writeFileSync, existsSync, chmodSync } from 'node:fs';
import { resolve } from 'node:path';
const dir = resolve(process.env.BILIGHT_LOCAL_DIR ?? '../Local', 'secrets'), key = resolve(dir, 'master-key');
mkdirSync(dir, { recursive: true, mode: 0o700 });
chmodSync(dir, 0o700);
if (!existsSync(key)) writeFileSync(key, randomBytes(32), { mode: 0o600, flag: 'wx' });
chmodSync(key, 0o600);
console.info('本地会话加密密钥已就绪；不会覆盖已有密钥。');
