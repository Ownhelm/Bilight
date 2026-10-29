import type { ApiErrorBody } from '../shared/types';

export class ApiError extends Error {
  constructor(public code: string, message: string, public status = 0) { super(message); this.name = 'ApiError'; }
}

export async function api<T>(url: string, options: { method?: string; body?: unknown; signal?: AbortSignal; keepalive?: boolean; silentAuthFailure?: boolean } = {}): Promise<T> {
  let response: Response;
  try {
    const method = options.method ?? 'GET';
    const headers: Record<string, string> = {};
    if (!['GET', 'HEAD'].includes(method)) headers['x-bilight-request'] = '1';
    if (options.body !== undefined) headers['Content-Type'] = 'application/json';
    response = await fetch(url, { method, credentials: 'same-origin', signal: options.signal, keepalive: options.keepalive, headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body) });
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw error;
    throw new ApiError('NETWORK_ERROR', '暂时连接不到本地服务，请稍后重试。');
  }
  const body: unknown = await response.json().catch((error: unknown) => { if (isAbort(error)) throw error; return null; });
  if (options.signal?.aborted) throw new DOMException('请求已取消。', 'AbortError');
  if (!response.ok) {
    const error = (body as ApiErrorBody | null)?.error;
    if (response.status === 401) window.dispatchEvent(new CustomEvent('bilight:session-expired', { detail: { silent: options.silentAuthFailure === true } }));
    throw new ApiError(error?.code ?? String(response.status), error?.message ?? '请求未完成，请稍后重试。', response.status);
  }
  return body as T;
}

export function errorMessage(error: unknown): string { return error instanceof Error ? error.message : '请求未完成，请稍后重试。'; }
export function isAbort(error: unknown): boolean { return error instanceof DOMException && error.name === 'AbortError'; }
export function officialVerificationUrl(value?: string): string | null {
  try {
    const url = new URL(value ?? '');
    return url.protocol === 'https:' && ['passport.bilibili.com', 'account.bilibili.com', 'safecenter.bilibili.com'].includes(url.hostname) ? url.href : null;
  } catch { return null; }
}
