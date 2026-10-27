import { existsSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const local = resolve(root, '../Local');
const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT || (existsSync(resolve(local, 'Dependencies/Android/sdk')) ? resolve(local, 'Dependencies/Android/sdk') : resolve(process.env.HOME, 'Library/Android/sdk'));
const java = process.env.JAVA_HOME || '/Applications/Android Studio.app/Contents/jbr/Contents/Home';
if (!existsSync(resolve(sdk, 'platform-tools/adb')) || !existsSync(resolve(java, 'bin/java'))) {
  throw new Error('请先安装 Android SDK，并设置 ANDROID_HOME 与 JAVA_HOME。详见 android/README.md。');
}
const gradle = process.env.GRADLE_USER_HOME || resolve(local, 'Builds/Android/gradle');
mkdirSync(gradle, { recursive: true });
const androidUser = process.env.ANDROID_USER_HOME || resolve(local, 'Dependencies/Android/user');
mkdirSync(androidUser, { recursive: true });
const env = { ...process.env, ANDROID_HOME: sdk, ANDROID_SDK_ROOT: sdk, ANDROID_USER_HOME: androidUser, JAVA_HOME: java, GRADLE_USER_HOME: gradle };
const mode = process.argv[2] || 'build';
const tasks = mode === 'test' ? [':app:testDebugUnitTest'] : mode === 'build' || mode === 'install' ? [':app:assembleDebug'] : null;
if (!tasks) throw new Error('用法：node scripts/android.mjs build|test|install');
const run = (command, args) => { const result = spawnSync(command, args, { cwd: root, env, stdio: 'inherit' }); if (result.status !== 0) process.exit(result.status || 1); };
run(resolve(root, 'android/gradlew'), ['-p', 'android', ...tasks, '--console=plain']);
if (mode === 'install') {
  const target = process.env.ANDROID_SERIAL ? ['-s', process.env.ANDROID_SERIAL] : ['-d'];
  run(resolve(sdk, 'platform-tools/adb'), [...target, 'install', '--no-streaming', '-r', resolve(root, 'android/app/build/outputs/apk/debug/app-debug.apk')]);
  run(resolve(sdk, 'platform-tools/adb'), [...target, 'shell', 'am', 'start', '-W', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER', '-n', 'app.bilight.android/.MainActivity']);
}
