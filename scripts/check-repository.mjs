import { execFileSync } from 'node:child_process';

// Check the actual Git index: .gitignore alone cannot exclude previously tracked media.
const files = execFileSync('git', ['ls-files', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean);
const denied = files.filter(path => {
  if (/^(?:releases?|Promotion|Local|Legal|video|artifacts|\.secrets)\//i.test(path)) return true;
  if (/^docs\/assets\//.test(path) && path !== 'docs/assets/logo.svg') return true;
  if (/^ios\/Bilight\/Demo\/.*\.(?:png|jpe?g|webp)$/i.test(path)) return true;
  return /\.(?:zip|ipa|dmg|p12|mobileprovision|wav|mp3|m4a|mov|mp4)$/i.test(path)
    && path !== 'ios/BilightTests/Fixtures/fullscreen-motion.mp4';
});
if (denied.length) {
  console.error('以下文件不应进入代码仓库：\n' + denied.join('\n'));
  process.exitCode = 1;
} else console.info('仓库边界检查通过：没有宣发素材、发布包或本地凭据。');
