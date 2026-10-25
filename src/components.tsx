import { useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ArrowLeft, ArrowRight, MagnifyingGlass, Play, SpinnerGap, WarningCircle } from '@phosphor-icons/react';
import type { VideoSummary } from '../shared/types';
import { api, errorMessage, isAbort } from './api';

export function useResource<T>(url: string | null, refresh = 0) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [loading, setLoading] = useState(Boolean(url));
  useEffect(() => {
    const controller = new AbortController();
    setData(null); setError(null); setLoading(Boolean(url));
    if (url) api<T>(url, { signal: controller.signal }).then(value => { if (!controller.signal.aborted) setData(value); }).catch((error: unknown) => {
      if (!controller.signal.aborted && !isAbort(error)) setError(error instanceof Error ? error : new Error(errorMessage(error)));
    }).finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [url, refresh]);
  return { data, error, loading };
}

export function SearchBox({ initial = '', large = false }: { initial?: string; large?: boolean }) {
  const navigate = useNavigate();
  const [input, setInput] = useState(initial);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const request = useRef<AbortController | null>(null);
  useEffect(() => { setInput(initial); }, [initial]);
  useEffect(() => () => request.current?.abort(), []);
  async function submit(event: FormEvent) {
    event.preventDefault(); const value = input.trim();
    if (!value || busy) return;
    setBusy(true); setError(''); const controller = new AbortController(); request.current = controller;
    try {
      const result = await api<{ path: string }>(`/api/resolve?input=${encodeURIComponent(value)}`, { signal: controller.signal });
      if (controller.signal.aborted) return;
      if (!/^\/(?:search(?:\?|$)|video\/|creator\/|following(?:\?|$)|$)/.test(result.path)) throw new Error('暂时无法打开这个链接。');
      navigate(result.path);
    } catch (error) { if (!isAbort(error)) setError(errorMessage(error)); }
    finally { if (!controller.signal.aborted) setBusy(false); }
  }
  return <div className={`search-wrap${large ? ' search-wrap-large' : ''}`}><form className="search-box" onSubmit={submit} role="search">
    <MagnifyingGlass aria-hidden="true" size={large ? 23 : 20} />
    <input aria-label="搜索视频、UP主或粘贴B站链接" placeholder={large ? '搜索视频、UP 主，或粘贴 B 站链接' : '搜索你想看的'} value={input} onChange={event => setInput(event.target.value)} maxLength={500} />
    {input && <button className="search-clear" type="button" aria-label="清空搜索" onClick={() => setInput('')}>×</button>}
    <button className="search-submit" type="submit" disabled={!input.trim() || busy} aria-label="搜索">{busy ? <SpinnerGap className="spin" size={20} /> : large ? <><span>搜索</span><ArrowRight size={18} /></> : <MagnifyingGlass size={20} />}</button>
  </form>{error && <p className="field-error" role="alert">{error}</p>}</div>;
}

export function Loading({ text = '正在加载' }: { text?: string }) { return <div className="status-block" role="status"><SpinnerGap className="spin" size={24} /><span>{text}</span></div>; }
export function Empty({ title, children, action }: { title: string; children?: ReactNode; action?: ReactNode }) {
  return <div className="empty-state"><div className="empty-symbol"><MagnifyingGlass size={30} weight="light" /></div><h2>{title}</h2>{children && <p>{children}</p>}{action}</div>;
}
export function Failure({ error, retry }: { error: unknown; retry?: () => void }) {
  return <div className="error-state" role="alert"><WarningCircle size={25} /><p>{errorMessage(error)}</p>{retry && <button className="button button-quiet" onClick={retry}>重新加载</button>}</div>;
}
export function Pagination({ page, hasMore, onChange }: { page: number; hasMore: boolean; onChange: (page: number) => void }) {
  if (page === 1 && !hasMore) return null;
  return <nav className="pagination" aria-label="分页"><button className="button button-quiet" disabled={page <= 1} onClick={() => onChange(page - 1)}><ArrowLeft size={16} />上一页</button><span>第 {page} 页</span><button className="button button-quiet" disabled={!hasMore} onClick={() => onChange(page + 1)}>下一页<ArrowRight size={16} /></button></nav>;
}

export function duration(seconds: number): string {
  const value = Math.max(0, Math.floor(seconds || 0));
  return value >= 3600 ? `${Math.floor(value / 3600)}:${String(Math.floor(value / 60) % 60).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}` : `${Math.floor(value / 60)}:${String(value % 60).padStart(2, '0')}`;
}
export function dateLabel(timestamp: number): string {
  if (!timestamp) return '';
  const date = new Date(timestamp < 1e12 ? timestamp * 1000 : timestamp);
  return date.toLocaleDateString('zh-CN', { year: 'numeric', month: 'numeric', day: 'numeric' });
}
export function countLabel(value?: number): string { return value === undefined ? '' : value >= 10000 ? `${(value / 10000).toFixed(value >= 1000000 ? 0 : 1)}万` : value.toLocaleString('zh-CN'); }

function DeferredCover({ src, priority }: { src: string; priority: boolean }) {
  const image = useRef<HTMLImageElement>(null);
  const [visible, setVisible] = useState(priority || typeof IntersectionObserver === 'undefined');
  useEffect(() => {
    if (priority) { setVisible(true); return; }
    if (visible || !image.current) return;
    const observer = new IntersectionObserver(entries => {
      if (entries.some(entry => entry.isIntersecting)) { setVisible(true); observer.disconnect(); }
    }, { rootMargin: '120px 0px' });
    observer.observe(image.current);
    return () => observer.disconnect();
  }, [priority, visible]);
  return <img ref={image} src={visible ? src : undefined} alt="" loading="eager" decoding="async" fetchPriority={priority ? 'high' : 'auto'} referrerPolicy="no-referrer" />;
}

export function VideoGrid({ videos, columns }: { videos: VideoSummary[]; columns?: number }) {
  return <div className="video-grid">{videos.map((video, index) => <article className="video-card" key={video.bvid}>
    <Link className="video-cover" to={`/video/${video.bvid}`} aria-label={`观看 ${video.title}`}>{columns ? <DeferredCover src={video.cover} priority={index < columns} /> : <img src={video.cover} alt="" loading="lazy" referrerPolicy="no-referrer" />}<span className="duration">{duration(video.duration)}</span><span className="cover-play" aria-hidden="true"><Play weight="fill" size={23} /></span></Link>
    <h2><Link to={`/video/${video.bvid}`}>{video.title}</Link></h2>
    <Link className="video-owner" to={`/creator/${video.owner.mid}`}><span className="up-tag">UP</span>{video.owner.name}</Link>
    <p className="video-meta">{video.views !== undefined && <span>{countLabel(video.views)} 播放</span>}<span>{dateLabel(video.publishedAt)}</span></p>
  </article>)}</div>;
}
