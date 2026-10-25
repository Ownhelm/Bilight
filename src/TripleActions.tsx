import { useEffect, useRef, useState, type KeyboardEvent, type PointerEvent } from 'react';
import { ArrowClockwise, Check, Coins, Plus, SpinnerGap, Star, ThumbsUp, X } from '@phosphor-icons/react';
import type { AuthState, CoinInfo, EngagementAction, FavoriteFolder, TripleResult, VideoEngagement, VideoInteraction } from '../shared/types';
import { api, ApiError, errorMessage, isAbort } from './api';
import { countLabel } from './components';
import { coinChoices, engagementCounts, favoriteChanged } from './interactionModel';
import { createLikePress, LIKE_CHARGE_MS } from './likePress';

export function TripleActions({ bvid, auth, onLogin, snapshot }: { bvid: string; auth: AuthState | null; onLogin: () => void; snapshot?: VideoInteraction }) {
  const [state, setState] = useState<VideoEngagement | null>(null);
  const [busy, setBusy] = useState(false), [working, setWorking] = useState('');
  const [message, setMessage] = useState(''), [error, setError] = useState('');
  const [retryRequired, setRetryRequired] = useState(false);
  const [holding, setHolding] = useState(false), [panel, setPanel] = useState<'coin' | 'favorite' | null>(null);
  const [panelLoading, setPanelLoading] = useState(false), [coins, setCoins] = useState<1 | 2>(2);
  const [coinLimit, setCoinLimit] = useState<1 | 2>(snapshot?.coinLimit ?? 2), [selectLike, setSelectLike] = useState(true), [experience, setExperience] = useState<number | null>(null);
  const [folders, setFolders] = useState<FavoriteFolder[]>([]), [folderIds, setFolderIds] = useState<number[]>([]);
  const [adding, setAdding] = useState(false), [folderName, setFolderName] = useState(''), [celebrating, setCelebrating] = useState('');
  const mount = useRef<HTMLDivElement>(null), dialog = useRef<HTMLDialogElement>(null), createInput = useRef<HTMLInputElement>(null);
  const active = useRef<AbortController | null>(null), statusRequest = useRef<AbortController | null>(null), baseline = useRef<VideoEngagement | null>(null);
  const actions = useRef({ like() {}, triple() {}, coin() {}, favorite() {}, canHold: (): boolean => true });
  const press = useRef<ReturnType<typeof createLikePress> | null>(null), origin = useRef({ x: 0, y: 0 });
  if (!press.current) press.current = createLikePress(() => actions.current.like(), () => actions.current.triple(), setHolding, () => actions.current.canHold());
  const complete = Boolean(state?.liked && state.coins > 0 && state.favorited), counts = engagementCounts(snapshot, baseline.current, state);
  const choices = coinChoices(coinLimit, state?.coins ?? 0), changed = favoriteChanged(folders, folderIds);
  function updateState(current: VideoEngagement) { baseline.current ??= current; setState(current); }
  async function readState(signal?: AbortSignal) { const current = await api<VideoEngagement>(`/api/videos/${bvid}/engagement`, { signal }); if (!signal?.aborted) updateState(current); return current; }
  useEffect(() => {
    if (!auth?.authenticated || !mount.current) return;
    const controller = new AbortController(); statusRequest.current = controller; let started = false;
    const load = () => { if (started) return; started = true; void readState(controller.signal).catch(error => { if (!isAbort(error)) setError(errorMessage(error)); }); };
    if (!('IntersectionObserver' in window)) load();
    const observer = 'IntersectionObserver' in window ? new IntersectionObserver(entries => { if (entries.some(entry => entry.isIntersecting)) { load(); observer?.disconnect(); } }, { rootMargin: '120px' }) : null;
    observer?.observe(mount.current);
    return () => { controller.abort(); observer?.disconnect(); };
  }, [bvid, auth?.authenticated]);
  useEffect(() => () => { active.current?.abort(); statusRequest.current?.abort(); press.current?.dispose(); }, []);
  useEffect(() => {
    if (!panel || !dialog.current) return;
    const current = dialog.current; current.showModal();
    return () => { if (current.open) current.close(); };
  }, [panel]);
  useEffect(() => { if (adding) createInput.current?.focus(); }, [adding]);
  useEffect(() => { if (!message) return; const timer = setTimeout(() => setMessage(''), 2500); return () => clearTimeout(timer); }, [message]);
  useEffect(() => { if (!celebrating) return; const timer = setTimeout(() => setCelebrating(''), 1300); return () => clearTimeout(timer); }, [celebrating]);
  useEffect(() => {
    if (!holding) return;
    const cancel = () => press.current?.cancel();
    window.addEventListener('blur', cancel); document.addEventListener('visibilitychange', cancel); window.addEventListener('scroll', cancel, true);
    return () => { window.removeEventListener('blur', cancel); document.removeEventListener('visibilitychange', cancel); window.removeEventListener('scroll', cancel, true); };
  }, [holding]);
  useEffect(() => {
    const shortcut = (event: globalThis.KeyboardEvent) => {
      const target = event.target instanceof HTMLElement ? event.target : null;
      if (event.defaultPrevented || event.repeat || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey || target?.isContentEditable || target?.closest('input,textarea,select') || document.querySelector('dialog[open],[role="dialog"]')) return;
      const action = ({ q: 'like', w: 'coin', e: 'favorite' } as const)[event.key.toLowerCase() as 'q' | 'w' | 'e'];
      if (action) { event.preventDefault(); actions.current[action](); }
    };
    document.addEventListener('keydown', shortcut); return () => document.removeEventListener('keydown', shortcut);
  }, []);

  async function submit(action: 'like' | 'triple' | 'refresh' | EngagementAction) {
    if (!auth?.authenticated) { onLogin(); return; }
    if (active.current) return;
    if (holding && action === 'like') return;
    if (retryRequired && action !== 'refresh') { setError('请先刷新互动状态确认上次结果。'); return; }
    if (action === 'triple' && complete) { setMessage('已经三连，感谢支持。'); return; }
    const controller = new AbortController(); active.current = controller;
    setBusy(true); setWorking(typeof action === 'string' ? action : action.type); setError(''); setMessage(''); statusRequest.current?.abort();
    try {
      if (action === 'refresh') { await readState(controller.signal); if (!controller.signal.aborted) { setRetryRequired(false); setMessage('已更新互动状态。'); } }
      else if (action === 'triple') {
        if (!baseline.current) await readState(controller.signal);
        if (controller.signal.aborted) return;
        const result = await api<TripleResult>(`/api/videos/${bvid}/triple`, { method: 'POST', signal: controller.signal });
        if (controller.signal.aborted) return;
        updateState(result.state); setCelebrating(result.complete ? 'triple' : '');
        setMessage(result.complete ? '三连成功，感谢支持 UP 主。' : '部分操作未完成，可刷新状态查看结果。');
      } else {
        const target = action === 'like' ? { type: 'like' as const, liked: !(await readState(controller.signal)).liked } : action;
        if (controller.signal.aborted) return;
        const result = await api<VideoEngagement>(`/api/videos/${bvid}/interaction`, { method: 'POST', body: target, signal: controller.signal });
        if (controller.signal.aborted) return;
        updateState(result); setPanel(null); if (target.type === 'like' && result.liked) setCelebrating('like');
        setMessage(target.type === 'like' ? result.liked ? '点赞成功。' : '已取消点赞。' : target.type === 'coin' ? `投币成功，感谢您的支持${target.selectLike && !result.liked ? '；点赞未完成，可单独重试' : ''}。` : result.favorited ? '收藏成功。' : '已取消收藏。');
      }
    } catch (error) { if (!isAbort(error)) { const uncertain = !(error instanceof ApiError) || ['NETWORK_ERROR', 'UPSTREAM_UNAVAILABLE', 'INTERACTION_UNCONFIRMED', 'TRIPLE_UNCONFIRMED'].includes(error.code); setRetryRequired(uncertain); setError(`${errorMessage(error)}${uncertain ? ' 请先刷新状态确认结果。' : ''}`); } }
    finally { if (!controller.signal.aborted) { active.current = null; setBusy(false); setWorking(''); } }
  }

  async function openPanel(next: 'coin' | 'favorite') {
    if (!auth?.authenticated) { onLogin(); return; }
    if (active.current) return;
    if (next === 'coin' && state && state.coins >= coinLimit) { setMessage('对本稿件的投币枚数已用完'); return; }
    press.current?.cancel(); statusRequest.current?.abort();
    const controller = new AbortController(); statusRequest.current = controller;
    setPanel(next); setPanelLoading(true); setError(''); setRetryRequired(false); setMessage(''); setAdding(false); setFolderName(''); setFolders([]); setFolderIds([]); setSelectLike(true); setExperience(null);
    try {
      if (next === 'coin') {
        // Experience is supplementary; a slow read must not lock the coin dialog.
        void api<{ experience: number }>(`/api/videos/${bvid}/coin-experience`, { signal: controller.signal }).then(value => { if (!controller.signal.aborted) setExperience(value.experience); }).catch(() => {});
        const info = await api<CoinInfo>(`/api/videos/${bvid}/coin-info`, { signal: controller.signal });
        if (controller.signal.aborted) return;
        updateState(info.state); setCoinLimit(info.coinLimit);
        const available = coinChoices(info.coinLimit, info.state.coins);
        if (!available.length) { setPanel(null); setMessage('对本稿件的投币枚数已用完'); }
        else setCoins(available[available.length - 1]);
      } else {
        const [, list] = await Promise.all([readState(controller.signal), api<{ items: FavoriteFolder[] }>(`/api/videos/${bvid}/favorite-folders`, { signal: controller.signal })]);
        if (controller.signal.aborted) return;
        setFolders(list.items); setFolderIds(list.items.filter(folder => folder.selected).map(folder => folder.id));
      }
    } catch (error) { if (!isAbort(error)) { setError(errorMessage(error)); setRetryRequired(true); } }
    finally { if (!controller.signal.aborted) setPanelLoading(false); }
  }
  async function createFolder() {
    if (active.current || !folderName.trim()) return;
    const controller = new AbortController(); active.current = controller; setBusy(true); setWorking('folder'); setError('');
    try {
      const folder = await api<FavoriteFolder>(`/api/videos/${bvid}/favorite-folders`, { method: 'POST', body: { title: folderName.trim() }, signal: controller.signal });
      if (controller.signal.aborted) return;
      setFolders(value => [...value.filter(item => item.id !== folder.id), folder]); setFolderIds(value => [...new Set([...value, folder.id])]); setAdding(false); setFolderName('');
    } catch (error) { if (!isAbort(error)) { setError(`${errorMessage(error)} 请刷新列表确认，避免重复新建。`); setRetryRequired(true); setAdding(false); } }
    finally { if (!controller.signal.aborted) { active.current = null; setBusy(false); setWorking(''); } }
  }
  actions.current = {
    like: () => void submit('like'), triple: () => void submit('triple'), coin: () => void openPanel('coin'), favorite: () => void openPanel('favorite'),
    canHold: () => { if (!auth?.authenticated) { onLogin(); return false; } if (complete) { setMessage('已经三连，感谢支持。'); return false; } return !active.current && !panel; },
  };
  function closePanel() { if (busy) return; statusRequest.current?.abort(); setPanel(null); setPanelLoading(false); setAdding(false); setFolderName(''); setError(''); }
  function start(event: PointerEvent<HTMLButtonElement>) { if (event.button === 0) { origin.current = { x: event.clientX, y: event.clientY }; press.current?.start(); } }
  function move(event: PointerEvent<HTMLButtonElement>) { if (event.pointerType === 'touch' && Math.hypot(event.clientX - origin.current.x, event.clientY - origin.current.y) > 12) press.current?.cancel(); }
  function keyDown(event: KeyboardEvent<HTMLButtonElement>) {
    if (event.key === ' ' || event.key === 'Enter') { event.preventDefault(); if (!event.repeat) press.current?.start(); }
    if (event.key === 'Escape') press.current?.cancel();
  }
  function keyUp(event: KeyboardEvent<HTMLButtonElement>) { if (event.key === ' ' || event.key === 'Enter') { event.preventDefault(); press.current?.end(); press.current?.click(); } }
  function ring() { return holding && <svg className="triple-ring" viewBox="0 0 40 40" aria-hidden="true"><circle cx="20" cy="20" r="18" pathLength="1" style={{ animationDuration: `${LIKE_CHARGE_MS}ms` }} /></svg>; }
  const disabled = !auth || busy;
  return <div className={`triple-actions${holding ? ' is-holding' : ''}${celebrating ? ` celebrate-${celebrating}` : ''}`} ref={mount} aria-label="支持 UP 主">
    <div className="triple-summary">
      <button type="button" className={`engagement-button like-button${state?.liked ? ' done' : ''}`} disabled={disabled} aria-label={state?.liked ? '取消点赞' : '点赞'} aria-pressed={Boolean(state?.liked)} aria-describedby={`triple-note-${bvid}`} title={`${state?.liked ? '已点赞' : '点赞'}（Q），长按一键三连`} onPointerDown={start} onPointerMove={move} onPointerUp={() => press.current?.end()} onPointerLeave={() => press.current?.cancel()} onPointerCancel={() => press.current?.cancel()} onBlur={() => press.current?.cancel()} onContextMenu={event => event.preventDefault()} onKeyDown={keyDown} onKeyUp={keyUp} onClick={() => press.current?.click()}>
        <span className="engagement-icon">{busy && (working === 'triple' || working === 'like') ? <SpinnerGap className="spin" size={28} /> : <ThumbsUp weight={state?.liked ? 'fill' : 'regular'} size={28} />}</span><span>{counts?.likes ? countLabel(counts.likes) : '点赞'}</span>
      </button>
      <button type="button" className={`engagement-button${state?.coins ? ' done' : ''}`} disabled={disabled} aria-label="投币" title={`投币（W）${state?.coins ? `，已投 ${state.coins} 枚` : ''}`} onClick={() => void openPanel('coin')}><span className="engagement-icon">{ring()}<Coins weight={state?.coins ? 'fill' : 'regular'} size={28} /></span><span>{counts?.coins ? countLabel(counts.coins) : '投币'}</span></button>
      <button type="button" className={`engagement-button${state?.favorited ? ' done' : ''}`} disabled={disabled} aria-label="收藏" title={`收藏（E）${state?.favorited ? '，已收藏' : ''}`} onClick={() => void openPanel('favorite')}><span className="engagement-icon">{ring()}<Star weight={state?.favorited ? 'fill' : 'regular'} size={28} /></span><span>{counts?.favorites ? countLabel(counts.favorites) : '收藏'}</span></button>
    </div>
    <div className="triple-submit">{complete && <span className="triple-complete"><Check size={16} />已三连</span>}<button className="triple-refresh" aria-label="刷新三连状态" title="刷新互动状态" disabled={!auth?.authenticated || busy} onClick={() => void submit('refresh')}><ArrowClockwise className={working === 'refresh' ? 'spin' : ''} size={18} /></button></div>
    <p id={`triple-note-${bvid}`} className="triple-note">长按点赞，圆环蓄满即可一键三连；蓄力中松开或移开取消。投币不可撤回，三连收藏到默认收藏夹。</p>
    {message && <p className="triple-message" role="status">{message}</p>}{error && !panel && <p className="triple-error" role="alert">{error}</p>}
    {panel && <dialog className="interaction-dialog" ref={dialog} aria-labelledby={`interaction-title-${bvid}`} onCancel={event => { event.preventDefault(); if (adding && !busy) { setAdding(false); setFolderName(''); } else closePanel(); }} onClick={event => { if (event.target === event.currentTarget) closePanel(); }}><div className="interaction-dialog-content"><button className="interaction-close" aria-label="关闭" disabled={busy} onClick={closePanel}><X size={20} /></button><h2 id={`interaction-title-${bvid}`}>{panel === 'coin' ? <>给 UP 主投上 <strong className="coin-amount">{coins}</strong> 枚硬币</> : '添加到收藏夹'}</h2>
      {panelLoading ? <p className="interaction-loading" role="status"><SpinnerGap className="spin" size={20} />正在读取{panel === 'coin' ? '投币状态' : '收藏夹'}</p> : <>{panel === 'coin' ? <><div className="coin-options">{choices.map(value => <button key={value} className={coins === value ? 'selected' : ''} disabled={busy} aria-pressed={coins === value} onClick={() => { setCoins(value); if (!retryRequired) setError(''); }}><Coins size={38} /><strong>{value} 枚硬币</strong></button>)}</div><label className="coin-like-option"><input type="checkbox" checked={selectLike} disabled={busy} onChange={event => { setSelectLike(event.target.checked); if (!retryRequired) setError(''); }} />同时点赞内容</label></> : <><div className="favorite-folders">{folders.length ? folders.map(folder => { const checked = folderIds.includes(folder.id), full = !checked && folder.count >= (folder.capacity ?? Infinity); return <label key={folder.id} className={full ? 'folder-full' : ''}><input type="checkbox" checked={checked} disabled={busy || adding || full} onChange={event => { const value = event.target.checked; if (!retryRequired) setError(''); setFolderIds(ids => value ? [...ids, folder.id] : ids.filter(id => id !== folder.id)); }} /><span>{folder.title}{folder.isPrivate && <em> [私密]</em>}{full && <em> [已满]</em>}</span><small>{Math.max(0, folder.count + Number(checked) - Number(folder.selected))}{!folder.isDefault && folder.capacity ? `/${folder.capacity}` : ''}</small></label>; }) : <p className="interaction-description">还没有收藏夹，可以在下面新建。</p>}</div>
        {adding ? <form className="favorite-create-form" onSubmit={event => { event.preventDefault(); void createFolder(); }}><p>新建公开收藏夹，最多20个字。</p><div><input ref={createInput} aria-label="收藏夹名称" placeholder="最多可输入20个字" maxLength={20} value={folderName} disabled={busy} onChange={event => setFolderName(event.target.value)} onKeyDown={event => { if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); if (!busy) { setAdding(false); setFolderName(''); } } }} /><button className="button button-primary" type="submit" disabled={busy || !folderName.trim()}>{working === 'folder' ? <SpinnerGap className="spin" size={16} /> : '新建'}</button></div><button type="button" className="favorite-create-cancel" disabled={busy} onClick={() => { setAdding(false); setFolderName(''); }}>取消新建</button></form> : <button className="favorite-create-trigger" disabled={busy || folders.length >= 100 || Boolean(error)} onClick={() => setAdding(true)}><Plus size={17} />{folders.length >= 100 ? '收藏夹个数已达到上限' : '新建收藏夹'}</button>}
      </>}
        {error && <p className="triple-error" role="alert">{error}</p>}<div className="interaction-footer"><button className="button button-quiet" disabled={busy} onClick={closePanel}>取消</button>{retryRequired ? <button className="button button-primary" disabled={busy} onClick={() => void openPanel(panel)}>刷新状态</button> : <button className="button button-primary" disabled={busy || adding || (panel === 'coin' ? !choices.includes(coins) : !changed)} onClick={() => void submit(panel === 'coin' ? { type: 'coin', coins: ((state?.coins ?? 0) + coins) as 1 | 2, selectLike } : { type: 'favorite', folderIds })}>{busy && working !== 'folder' ? <><SpinnerGap className="spin" size={16} />正在提交</> : '确定'}</button>}</div>
        {panel === 'coin' && experience !== null && <p className="coin-experience">{experience < 50 ? `经验值+${Math.min(coins * 10, 50 - experience)}（今日 ${experience}/50）` : '今日投币经验已达到50'}</p>}
      </>}
    </div></dialog>}
  </div>;
}
