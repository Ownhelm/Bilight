import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(readFileSync(resolve(root, 'branding/manifest.json'), 'utf8'));
const digest = value => createHash('sha256').update(value).digest('hex');
const sources = Object.fromEntries(Object.entries(manifest.marks).map(([name, path]) => [name, readFileSync(resolve(root, path))]));
const hashes = Object.fromEntries(Object.entries(sources).map(([name, data]) => [name, digest(data)]));
const write = process.argv.includes('--write');
const lockPath = resolve(root, 'branding/generated.json');
const targets = [
  ['project', 'docs/assets/logo.svg'],
  ['playback', 'ios/Bilight/Assets.xcassets/PlaybackMark.imageset/playback-mark.svg'],
];
const promotion = resolve(root, '../Promotion');
if (existsSync(promotion)) targets.push(
  ['project', '../Promotion/Video/public/assets/logo.svg'],
  ['project', '../Promotion/Video/public/assets/brand/project-mark.svg'],
  ['playback', '../Promotion/Video/public/assets/brand/playback-mark.svg'],
  ['appIcon', '../Promotion/Video/public/assets/brand/app-icon.svg'],
  ['project', '../Promotion/Bilibili/Shared/Assets/logo.svg'],
);
if (write) {
  for (const [name, path] of targets) {
    const target = resolve(root, path); mkdirSync(dirname(target), { recursive: true }); writeFileSync(target, sources[name]);
  }
  const imageset = resolve(root, 'ios/Bilight/Assets.xcassets/PlaybackMark.imageset/Contents.json');
  writeFileSync(imageset, JSON.stringify({ images: [{ filename: 'playback-mark.svg', idiom: 'universal' }], info: { author: 'xcode', version: 1 }, properties: { 'preserves-vector-representation': true, 'template-rendering-intent': 'template' } }, null, 2) + '\n');
  // AppIcon is a build resource; only this maintenance command needs librsvg.
  execFileSync('rsvg-convert', ['-w', '1024', '-h', '1024', resolve(root, manifest.marks.appIcon), '-o', resolve(root, 'ios/Bilight/Assets.xcassets/AppIcon.appiconset/AppIcon.png')]);
  writeFileSync(lockPath, JSON.stringify({ revision: manifest.revision, sourceHashes: hashes, appIconPngSha256: digest(readFileSync(resolve(root, 'ios/Bilight/Assets.xcassets/AppIcon.appiconset/AppIcon.png'))) }, null, 2) + '\n');
  if (existsSync(promotion)) writeFileSync(resolve(promotion, 'Video/public/assets/brand/manifest.json'), JSON.stringify({ ...manifest, sourceHashes: hashes }, null, 2) + '\n');
}
const failures = [];
for (const [name, path] of targets) if (!existsSync(resolve(root, path)) || digest(readFileSync(resolve(root, path))) !== hashes[name]) failures.push(`旧品牌副本：${path}`);
const lock = existsSync(lockPath) ? JSON.parse(readFileSync(lockPath)) : {};
if (JSON.stringify(lock.sourceHashes) !== JSON.stringify(hashes)) failures.push('App 图标生成记录未同步');
if (digest(readFileSync(resolve(root, 'ios/Bilight/Assets.xcassets/AppIcon.appiconset/AppIcon.png'))) !== lock.appIconPngSha256) failures.push('AppIcon PNG 与生成记录不符');
for (const path of ['src/App.tsx', 'src/styles.css', '../Promotion/Video/src/film.tsx', '../Promotion/Video/src/style.css']) {
  const target = resolve(root, path);
  if (existsSync(target) && /brand-dot|TelevisionSimple/.test(readFileSync(target, 'utf8'))) failures.push(`旧品牌代码：${path}`);
}
if (!readFileSync(resolve(root, 'README.md'), 'utf8').includes('src="branding/project-mark.svg"')) failures.push('README 未直接引用统一的项目标志');
if (!readFileSync(resolve(root, 'src/App.tsx'), 'utf8').includes('branding/playback-mark.svg')) failures.push('网页未引用统一的播放标志');
if (!readFileSync(resolve(root, 'Dockerfile'), 'utf8').includes('COPY branding ./branding')) failures.push('Docker 构建遗漏品牌源目录');
if (!readFileSync(resolve(root, 'ios/Bilight/Features/SearchView.swift'), 'utf8').includes('Image("PlaybackMark")')) failures.push('iPhone 首页未引用统一的播放标志');
if (existsSync(promotion) && !write) {
  const recordPath = resolve(promotion, 'Screenshots/brand-assets.json');
  if (!existsSync(recordPath)) failures.push('宣发衍生图缺少来源记录');
  else {
    const record = JSON.parse(readFileSync(recordPath));
    for (const [path, expected] of Object.entries({ ...record.inputs, ...record.outputs })) {
      const file = resolve(root, '..', path);
      if (!existsSync(file) || digest(readFileSync(file)) !== expected) failures.push(`衍生图或输入已变化，请重新生成：${path}`);
    }
  }
  for (const name of ['web-home.png', 'web-following.png', 'web-collections.png', 'ios-home.png', 'ios-following.png', 'ios-account.png']) {
    if (digest(readFileSync(resolve(promotion, 'Screenshots', name))) !== digest(readFileSync(resolve(promotion, 'Video/public/assets', name)))) failures.push(`视频截图副本过期：${name}`);
  }
  const videoManifest = resolve(promotion, 'Video/public/assets/brand/manifest.json');
  if (!existsSync(videoManifest) || JSON.stringify(JSON.parse(readFileSync(videoManifest)).sourceHashes) !== JSON.stringify(hashes)) failures.push('视频内嵌品牌清单过期');
  const shared = resolve(promotion, 'Bilibili/Shared');
  const vectorFolders = [resolve(shared, 'Templates'), resolve(shared, 'Channel')];
  for (const entry of readdirSync(resolve(promotion, 'Bilibili/Episodes'))) {
    const episodeRoot = resolve(promotion, 'Bilibili/Episodes', entry), file = resolve(episodeRoot, 'episode.json');
    if (!existsSync(file)) continue;
    const episode = JSON.parse(readFileSync(file)), versionRoot = resolve(episodeRoot, 'Versions', episode.currentVersion);
    vectorFolders.push(resolve(versionRoot, 'Cover'));
    if (episode.id === '001-introduction') {
      const release = JSON.parse(readFileSync(resolve(versionRoot, 'manifest.json')));
      const exported = resolve(versionRoot, release.exportDirectory), change = JSON.parse(readFileSync(resolve(exported, 'brand-change.json')));
      if (JSON.stringify(change.sourceHashes) !== JSON.stringify(hashes)) failures.push('当前成片未使用最新品牌源，请重新渲染');
      for (const [name, expected] of Object.entries(change.screenshots ?? {})) if (digest(readFileSync(resolve(promotion, 'Screenshots', name))) !== expected) failures.push(`当前成片还在使用旧截图：${name}`);
    }
  }
  for (const folder of vectorFolders) if (existsSync(folder)) for (const file of readdirSync(folder).filter(name => name.endsWith('.svg'))) {
    const text = readFileSync(resolve(folder, file), 'utf8');
    for (const match of text.matchAll(/data:image\/svg\+xml;base64,([A-Za-z0-9+/=]+)/g)) if (!Object.values(hashes).includes(digest(Buffer.from(match[1], 'base64')))) failures.push(`模板内嵌了旧标志：${folder}/${file}`);
  }
}
if (failures.length) { console.error(failures.join('\n')); process.exitCode = 1; }
else console.info(`品牌检查通过：${manifest.revision}，${targets.length} 个副本与源码一致。`);
