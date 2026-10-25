import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { ArrowClockwise, ArrowLeft, ArrowRight, ClockCounterClockwise } from '@phosphor-icons/react';
import type { AuthState, HistoryItem, Page } from '../shared/types';
import { duration, Empty, Failure, Loading, useResource } from './components';
import { historyDay, historyHref } from './historyRecords';

function HistoryRows({ items, compact = false }: { items: HistoryItem[]; compact?: boolean }) {
  let previousDay = '';
  return <div className={compact ? 'history-items compact' : 'history-items'}>{items.map(item => {
    const day = historyDay(item.viewedAt), showDay = !compact && day !== previousDay; previousDay = day;
    const completed = item.progress < 0 || (item.duration > 0 && item.progress >= item.duration);
    const progress = completed ? 100 : item.duration > 0 ? Math.min(100, item.progress / item.duration * 100) : 0;
    return <div key={item.bvid}>{showDay && <h2 className="history-day">{day}</h2>}<Link className="history-row" to={historyHref(item)}>
      <div className="history-cover">{item.cover && <img src={item.cover} alt="" loading="lazy" />}<span className="duration">{duration(item.duration)}</span><span className="history-progress" style={{ width: `${progress}%` }} /></div>
      <div className="history-info"><h3>{item.title}</h3>{item.page > 1 && <p className="history-part">P{item.page} · {item.part}</p>}<p className="history-owner">{item.owner.name}</p><p className="history-meta"><span>{completed ? '已看完' : item.progress > 0 ? `观看至 ${duration(item.progress)}` : '刚刚开始'}</span><span>{compact ? day : ''} {new Date(item.viewedAt * 1000).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}</span></p></div>
    </Link></div>;
  })}</div>;
}

export function HistoryMenu({ auth, onLogin }: { auth: AuthState | null; onLogin: () => void }) {
  const details = useRef<HTMLDetailsElement>(null); const location = useLocation();
  const [open, setOpen] = useState(false), [refresh, setRefresh] = useState(0);
  const { data, error, loading } = useResource<Page<HistoryItem>>(open && auth?.authenticated ? `/api/history?limit=6` : null, refresh);
  const update = useCallback(() => setRefresh(value => value + 1), []);
  useHistoryUpdates(open && !!auth?.authenticated, update);
  useEffect(() => { if (details.current) details.current.open = false; }, [location.pathname, location.search]);
  useEffect(() => {
    if (!open) return;
    const close = (event: PointerEvent) => { if (!details.current?.contains(event.target as Node) && details.current) details.current.open = false; };
    const escape = (event: KeyboardEvent) => { if (event.key === 'Escape' && details.current) details.current.open = false; };
    document.addEventListener('pointerdown', close); document.addEventListener('keydown', escape);
    return () => { document.removeEventListener('pointerdown', close); document.removeEventListener('keydown', escape); };
  }, [open]);
  return <details className="history-menu" ref={details} onToggle={event => setOpen(event.currentTarget.open)}><summary aria-label="我的历史"><ClockCounterClockwise size={21} /><span><span className="history-my">我的</span>历史</span></summary>
    {open && <div className="history-popover"><div className="history-popover-heading"><h2>我的历史</h2><Link to="/history">查看全部<ArrowRight size={13} /></Link></div>

      {!auth ? <Loading text="正在连接账号" /> : !auth.authenticated ? <div className="history-login"><p>登录后查看当前账号的播放历史。</p><button className="button button-primary" onClick={() => { if (details.current) details.current.open = false; onLogin(); }}>登录哔哩哔哩</button></div> : loading ? <Loading text="正在读取播放历史" /> : error ? <Failure error={error} retry={() => setRefresh(value => value + 1)} /> : data?.items.length ? <HistoryRows items={data.items} compact /> : <p className="history-empty">{data?.hasMore ? '最近记录中没有普通视频，可进入全部历史继续查看。' : '暂无观看记录。'}</p>}
    </div>}
  </details>;
}

export function HistoryPage({ auth, onLogin }: { auth: AuthState | null; onLogin: () => void }) {
  const [page, setPage] = useState(1), [cursors, setCursors] = useState(['']), [refresh, setRefresh] = useState(0);
  const cursor = cursors[page - 1];
  const { data, error, loading } = useResource<Page<HistoryItem>>(auth?.authenticated ? `/api/history?${cursor ? `cursor=${encodeURIComponent(cursor)}` : ''}` : null, refresh);
  const update = useCallback(() => { setPage(1); setCursors(['']); setRefresh(value => value + 1); }, []);
  useHistoryUpdates(!!auth?.authenticated, update);
  useEffect(() => { document.title = '我的历史 · Bilight'; }, []);
  const next = data?.nextCursor && !cursors.slice(0, page).includes(data.nextCursor) ? data.nextCursor : '';
  return <div className="page-container history-page"><div className="page-heading"><div><p className="section-eyebrow">看过的内容，随时回来</p><h1>我的历史</h1></div>{auth?.authenticated && <button className="button button-quiet" disabled={loading} onClick={() => { setPage(1); setCursors(['']); setRefresh(value => value + 1); }}><ArrowClockwise size={16} />刷新记录</button>}</div>
    {!auth ? <Loading text="正在连接账号" /> : !auth.authenticated ? <Empty title="登录后查看播放历史" action={<button className="button button-primary" onClick={onLogin}>登录哔哩哔哩</button>}>使用你已有的 B 站账号。</Empty> : loading ? <Loading text="正在读取播放历史" /> : error ? <Failure error={error} retry={() => setRefresh(value => value + 1)} /> : data?.items.length ? <HistoryRows items={data.items} /> : <Empty title={data?.hasMore ? '本页没有普通视频记录' : '暂时没有普通视频播放记录'}>{data?.hasMore ? '可以继续翻页查看。' : ''}</Empty>}
    {auth?.authenticated && (page > 1 || next) && <nav className="pagination" aria-label="历史分页"><button className="button button-quiet" disabled={loading || page <= 1} onClick={() => setPage(value => value - 1)}><ArrowLeft size={16} />上一页</button><span>第 {page} 页</span><button className="button button-quiet" disabled={loading || !next} onClick={() => { setCursors(value => [...value.slice(0, page), next]); setPage(value => value + 1); }}>下一页<ArrowRight size={16} /></button></nav>}
  </div>;
}

function useHistoryUpdates(active: boolean, refresh: () => void) {
  useEffect(() => {
    if (!active) return;
    let timer: ReturnType<typeof setTimeout>;
    const update = () => { if (document.visibilityState === 'visible') { clearTimeout(timer); timer = setTimeout(refresh, 250); } };
    window.addEventListener('bilight:history-updated', update);
    window.addEventListener('focus', update);
    document.addEventListener('visibilitychange', update);
    return () => { clearTimeout(timer); window.removeEventListener('bilight:history-updated', update); window.removeEventListener('focus', update); document.removeEventListener('visibilitychange', update); };
  }, [active, refresh]);
}
