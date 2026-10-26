import { mkdirSync, writeFileSync } from 'node:fs';
import { nativeFixtures } from './demo-fixtures.mjs';
mkdirSync('ios/Bilight/Demo', { recursive: true });
writeFileSync('ios/Bilight/Demo/fixtures.json', JSON.stringify(nativeFixtures, null, 2) + '\n');
console.info('已生成演示账号与指定 UP 主公开内容的 iPhone 离线快照。');
