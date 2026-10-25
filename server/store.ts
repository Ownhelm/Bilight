import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { chmodSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import Database from 'better-sqlite3';

/** Only encrypted values enter SQLite; the key stays in the deployment secret. */
export class SecretStore {
  private readonly db: Database.Database;
  constructor(path: string, private readonly key: Buffer) {
    if (key.length !== 32) throw new Error('BILIGHT_SECRET_KEY 必须解码为 32 字节');
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new Database(path);
    this.db.pragma('journal_mode = DELETE');
    this.db.exec('CREATE TABLE IF NOT EXISTS secrets (name TEXT PRIMARY KEY, value BLOB NOT NULL)');
    if (path !== ':memory:') chmodSync(path, 0o600);
  }
  get<T>(name: string): T | undefined {
    const row = this.db.prepare('SELECT value FROM secrets WHERE name = ?').get(name) as { value: Buffer } | undefined;
    if (!row) return undefined;
    try {
      const data = row.value;
      const decipher = createDecipheriv('aes-256-gcm', this.key, data.subarray(0, 12));
      decipher.setAAD(Buffer.from(name));
      decipher.setAuthTag(data.subarray(12, 28));
      return JSON.parse(Buffer.concat([decipher.update(data.subarray(28)), decipher.final()]).toString('utf8')) as T;
    } catch { throw new Error('无法解密本地登录数据，请检查持久化密钥'); }
  }
  set(name: string, value: unknown): void {
    const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', this.key, iv);
    cipher.setAAD(Buffer.from(name));
    const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
    this.db.prepare('INSERT INTO secrets(name,value) VALUES (?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value').run(name, Buffer.concat([iv, cipher.getAuthTag(), ciphertext]));
  }
  delete(name: string): void { this.db.prepare('DELETE FROM secrets WHERE name = ?').run(name); }
  close(): void { this.db.close(); }
}
