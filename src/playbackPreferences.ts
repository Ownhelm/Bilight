type PreferenceStorage = Pick<Storage, 'getItem' | 'setItem'>;
const key = 'bilight:playback-preferences:v1';
const validQuality = (value: unknown): value is number => Number.isInteger(value) && Number(value) > 0 && Number(value) <= 127;

function browserStorage(): PreferenceStorage | undefined {
  try { return globalThis.localStorage; } catch { return undefined; }
}

/** Only explicit choices are saved; an unavailable stream never lowers the remembered quality. */
export class PlaybackPreferences {
  private value = { danmaku: false, quality: 127 };
  constructor(private storage = browserStorage()) {
    try {
      const saved = JSON.parse(storage?.getItem(key) ?? 'null');
      if (typeof saved?.danmaku === 'boolean') this.value.danmaku = saved.danmaku;
      if (validQuality(saved?.quality)) this.value.quality = saved.quality;
    } catch { /* Unavailable or corrupt storage keeps the initial defaults. */ }
  }
  get danmaku() { return this.value.danmaku; }
  get quality() { return this.value.quality; }
  setDanmaku(enabled: boolean) { this.value.danmaku = enabled; this.save(); }
  setQuality(quality: number) { if (validQuality(quality)) { this.value.quality = quality; this.save(); } }
  private save() { try { this.storage?.setItem(key, JSON.stringify(this.value)); } catch { /* Keep the choice for this session when storage is blocked. */ } }
}

export const playbackPreferences = new PlaybackPreferences();
