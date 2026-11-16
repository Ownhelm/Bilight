import { createContext, useContext, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { ArrowClockwise, Check, SpinnerGap, X } from '@phosphor-icons/react';
import type { AuthState, WatchLaterItem } from '../shared/types';
import { errorMessage, isAbort } from './api';
import { duration, Empty, Failure, Loading } from './components';
import { WatchLaterStore } from './watchLaterStore';
import './watchLater.css';

const WatchLaterContext = createContext<{ store: WatchLaterStore; onLogin: () => void } | null>(null);

export function WatchLaterProvider({ store, onLogin, active, children }: { store: WatchLaterStore; onLogin: () => void; active: boolean; children: ReactNode }) {
  useEffect(() => store.attach(), [store]);
  useEffect(() => {
    if (!active || !store.accountMid) return;
    let timer: ReturnType<typeof setTimeout>;
    const refresh = () => { void store.refreshMembership(true).catch(() => {}); };
    const visible = () => {
      if (document.visibilityState !== 'visible') return;
      clearTimeout(timer);
      timer = setTimeout(refresh, 250);
    };
    refresh();
    document.addEventListener('visibilitychange', visible);
    window.addEventListener('focus', visible);
    return () => {
      clearTimeout(timer);
      document.removeEventListener('visibilitychange', visible);
      window.removeEventListener('focus', visible);
    };
  }, [store, active]);
  return <WatchLaterContext.Provider value={{ store, onLogin }}>{children}</WatchLaterContext.Provider>;
}

function useWatchLater() {
  const context = useContext(WatchLaterContext);
  if (!context) throw new Error('缺少稍后再看账号会话。');
  const state = useSyncExternalStore(context.store.subscribe, context.store.snapshot);
  return { ...context, ...state };
}

export function WatchLaterGlyph({ saved = false }: { saved?: boolean }) {
  return <span className={`watch-later-glyph${saved ? ' watch-later-glyph-saved' : ''}`} aria-hidden="true" />;
}

export function WatchLaterButton({ aid, inPlayer = false, onLogin }: { aid: number; inPlayer?: boolean; onLogin?: () => void }) {
  const { store, onLogin: openLogin, aids, pending } = useWatchLater();
  const [error, setError] = useState('');
  useEffect(() => { setError(''); }, [store, aid]);
  if (!Number.isSafeInteger(aid) || aid <= 0) return null;
  const saved = aids.has(aid);
  const busy = pending.has(aid);
  const action = saved ? '移出稍后再看' : '稍后再看';
  async function toggle() {
    if (busy) return;
    setError('');
    if (!store.accountMid) { (onLogin ?? openLogin)(); return; }
    try { await store.set(aid, !saved); }
    catch (error) { if (!isAbort(error)) setError(`稍后再看操作未确认：${errorMessage(error)}`); }
  }
  return <div className={`watch-later-action${inPlayer ? ' watch-later-action-player' : ''}`}>
    <button type="button" className="watch-later-toggle" aria-label="稍后再看" aria-pressed={saved} aria-busy={busy} aria-disabled={busy}
      onKeyDown={event => { if (event.key === ' ' || event.key === 'Enter') event.stopPropagation(); }}
      onClick={event => { event.stopPropagation(); void toggle(); }}>
      {busy ? <SpinnerGap className="spin" size={20} /> : <WatchLaterGlyph saved={saved} />}
    </button>
    <span className="watch-later-tooltip" aria-hidden="true">{action}</span>
    {error && <div className="watch-later-card-error" role="alert">{error}<button type="button" aria-label="关闭提示" onClick={event => { event.stopPropagation(); setError(''); }}><X size={14} /></button></div>}
  </div>;
}

type Retiring = { item: WatchLaterItem; index: number };

function watchLaterHref(item: WatchLaterItem) {
  if (item.cid <= 0) return `/video/${item.bvid}`;
  const params = new URLSearchParams({ cid: String(item.cid) });
  if (item.progress > 0) params.set('t', String(Math.floor(item.progress)));
  return `/video/${item.bvid}?${params}`;
}

export function WatchLaterPage({ auth, onLogin }: { auth: AuthState | null; onLogin: () => void }) {
  const { store, list, listLoading, listError, pending } = useWatchLater();
  const [selected, select] = useState<number[] | null>(null);
  const [confirming, confirm] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [error, setError] = useState('');
  const [undo, setUndo] = useState<number[]>([]);
  const [undoBusy, setUndoBusy] = useState(false);
  const [undoPaused, setUndoPaused] = useState(false);
  const [retiring, setRetiring] = useState<Retiring[]>([]);
  const dialog = useRef<HTMLDialogElement>(null);
  const page = useRef<HTMLDivElement>(null);
  const timers = useRef(new Set<ReturnType<typeof setTimeout>>());
  const focusAfterRemove = useRef<number | null>(null);
  const items = list?.items ?? [];

  useEffect(() => {
    document.title = '稍后再看 · Bilight';
    if (!store.accountMid) return;
    let timer: ReturnType<typeof setTimeout>;
    void store.loadList();
    const refreshOnFocus = () => {
      if (document.visibilityState !== 'visible') return;
      clearTimeout(timer);
      timer = setTimeout(() => void store.loadList(), 250);
    };
    document.addEventListener('visibilitychange', refreshOnFocus);
    window.addEventListener('focus', refreshOnFocus);
    return () => {
      clearTimeout(timer);
      timers.current.forEach(clearTimeout);
      timers.current.clear();
      document.removeEventListener('visibilitychange', refreshOnFocus);
      window.removeEventListener('focus', refreshOnFocus);
    };
  }, [store]);
  useEffect(() => {
    if (!undo.length || undoBusy || undoPaused) return;
    const timeout = setTimeout(() => setUndo([]), 6500);
    return () => clearTimeout(timeout);
  }, [undo, undoBusy, undoPaused]);
  useLayoutEffect(() => {
    if (confirming && dialog.current && !dialog.current.open) dialog.current.showModal();
    if (!confirming && dialog.current?.open) dialog.current.close();
  }, [confirming]);
  useLayoutEffect(() => {
    const index = focusAfterRemove.current;
    if (index === null || retiring.length || !page.current) return;
    focusAfterRemove.current = null;
    const actions = page.current.querySelectorAll<HTMLElement>('.watch-later-remove');
    (actions[Math.min(index, actions.length - 1)] ?? page.current.querySelector('h1'))?.focus({ preventScroll: true });
  }, [items, retiring, undo]);
  useEffect(() => {
    if (!list || removing) return;
    const shown = new Set(list.items.map(item => item.aid));
    select(current => current?.some(aid => !shown.has(aid)) ? current.filter(aid => shown.has(aid)) : current);
  }, [list, removing]);

  function pick(aid: number) {
    select(previous => previous?.includes(aid) ? previous.filter(value => value !== aid) : [...(previous ?? []), aid]);
  }
  async function remove(ids: number[], batch = false) {
    if (removing) return;
    const active = document.activeElement;
    const focused = active instanceof HTMLElement && ids.includes(Number(active.dataset.aid));
    const rows = items.flatMap((item, index) => ids.includes(item.aid) ? [{ item, index }] : []);
    const animated = !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (animated) setRetiring(current => [...current, ...rows]);
    setError(''); setRemoving(batch);
    let removed: number[] = [];
    try {
      removed = batch ? await store.remove(ids) : (await store.set(ids[0], false)) === false ? ids : [];
      if (!page.current) return;
      if (removed.length) {
        if (focused || batch) focusAfterRemove.current = rows.find(({ item }) => removed.includes(item.aid))?.index ?? 0;
        setUndo(removed);
      }
      if (batch) {
        const remaining = ids.filter(aid => !removed.includes(aid));
        select(remaining.length ? remaining : null);
        if (remaining.length) setError('部分视频未能移出，请刷新列表后重试。');
      }
    } catch (error) {
      if (!isAbort(error)) setError(`移出未确认：${errorMessage(error)}`);
    } finally {
      if (animated && page.current) {
        setRetiring(current => current.filter(({ item }) => !ids.includes(item.aid) || removed.includes(item.aid)));
        if (removed.length) {
          const timer = setTimeout(() => {
            timers.current.delete(timer);
            setRetiring(current => current.filter(({ item }) => !removed.includes(item.aid)));
          }, 180);
          timers.current.add(timer);
        }
      }
      setRemoving(false);
      if (batch) confirm(false);
    }
  }
  async function restore() {
    if (undoBusy || !undo.length) return;
    setError(''); setUndoBusy(true);
    const remaining: number[] = [];
    let failure: unknown = null;
    try {
      for (const aid of undo) {
        try { if (!await store.set(aid, true)) remaining.push(aid); }
        catch (error) { if (isAbort(error)) return; remaining.push(aid); failure = error; }
      }
      await store.loadList();
      setUndo(remaining);
      if (failure) setError(`部分视频未能重新加入：${errorMessage(failure)}`);
    } finally { setUndoBusy(false); }
  }

  const display = items.map(item => ({ item, leaving: false }));
  retiring.forEach(({ item, index }) => {
    if (!items.some(current => current.aid === item.aid)) display.splice(index, 0, { item, leaving: true });
  });
  return <div ref={page} className="page-container watch-later-page"><div className="page-heading"><h1 tabIndex={-1}>稍后再看</h1>
    {store.accountMid && <button className="button button-quiet watch-later-refresh" type="button" onClick={() => void store.loadList()} disabled={listLoading}><ArrowClockwise className={listLoading ? 'spin' : undefined} size={16} />刷新</button>}</div>
    {!auth ? <Loading text="正在连接账号" /> : !store.accountMid ? <Empty title="登录后查看稍后再看" action={<button className="button button-primary" onClick={onLogin}>登录哔哩哔哩</button>} />
      : !list && listError ? <Failure error={listError} retry={() => void store.retryList()} />
      : !list ? <Loading text="正在读取稍后再看" />
      : <>
        <div className="watch-later-list-heading"><span>{list.total} 个视频</span><span>最近添加</span>
          {selected || items.length > 0 ? <button className="text-button" onClick={() => select(selected ? null : [])}>{selected ? '取消' : '管理'}</button> : null}</div>
        {listError ? <Failure error={listError} retry={() => void store.retryList()} /> : null}
        {error && <p className="watch-later-write-error" role="alert">{error}</p>}
        {display.length ? <ul className="watch-later-list">{display.map(({ item, leaving }) => {
          const busy = pending.has(item.aid);
          const playable = !item.unavailable && Boolean(item.bvid);
          const marked = selected?.includes(item.aid) ?? false;
          const info = <><span className="watch-later-cover">{item.cover && <img src={item.cover} alt="" loading="lazy" referrerPolicy="no-referrer" />}{item.duration > 0 && <span className="duration">{duration(item.duration)}</span>}</span>
            <span className="watch-later-row-text"><strong>{item.title || '视频已失效'}</strong><small>{playable ? item.owner.name : '视频已失效'}</small></span></>;
          return <li className={leaving ? 'watch-later-row leaving' : 'watch-later-row'} key={item.aid} aria-hidden={leaving || undefined} inert={leaving}>
            <div className="watch-later-row-body">
              {selected ? <button type="button" className="watch-later-row-main" role="checkbox" aria-checked={marked} disabled={busy} onClick={() => pick(item.aid)}><span className="watch-later-checkbox" aria-hidden="true">{marked && <Check size={16} />}</span>{info}</button>
                : <>
                  {playable ? <Link className="watch-later-row-main" to={watchLaterHref(item)}>{info}</Link> : <div className="watch-later-row-main">{info}</div>}
                  <button type="button" className="watch-later-remove" data-aid={item.aid} aria-label={`移出 ${item.title || '失效视频'}`} aria-disabled={busy} onClick={() => { if (!busy) void remove([item.aid]); }}>{busy ? <SpinnerGap className="spin" size={18} /> : <X size={18} />}</button>
                </>}
            </div>
          </li>;
        })}</ul> : !listError && !list.nextPage && <Empty title="还没有稍后再看" action={<Link className="button button-primary" to="/search">去搜索</Link>} />}
        {list.nextPage && <div className="watch-later-more"><button type="button" className="button button-quiet" disabled={listLoading} onClick={() => void store.loadList(true)}>{listLoading ? '正在读取' : '加载更多'}</button></div>}
        {selected && <div className="watch-later-manage"><span>已选 {selected.length} 项</span><button type="button" className="text-button" disabled={!selected.length || removing} onClick={() => confirm(true)}>移出</button></div>}
        <dialog ref={dialog} className="interaction-dialog watch-later-confirm" aria-labelledby="watch-later-confirm-title" onCancel={event => { event.preventDefault(); if (!removing) confirm(false); }}>
          <div className="interaction-surface"><h2 id="watch-later-confirm-title">移出 {selected?.length ?? 0} 个视频？</h2>
          <div className="watch-later-confirm-actions"><button type="button" className="button button-quiet" autoFocus disabled={removing} onClick={() => confirm(false)}>取消</button>
          <button type="button" className="button button-primary" disabled={!selected?.length || removing} onClick={() => void remove(selected ?? [], true)}>{removing ? '正在移出' : '确认移出'}</button></div></div>
        </dialog>
        {undo.length > 0 && <div className="watch-later-undo" onMouseEnter={() => setUndoPaused(true)} onMouseLeave={() => setUndoPaused(false)} onFocus={() => setUndoPaused(true)} onBlur={() => setUndoPaused(false)}>
          <span role="status">已移出稍后再看</span><button className="text-button" onClick={() => void restore()} disabled={undoBusy}>{undoBusy ? '正在撤销' : '撤销'}</button>
        </div>}
      </>}
  </div>;
}
