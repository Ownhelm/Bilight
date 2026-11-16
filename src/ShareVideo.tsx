import { useEffect, useRef, useState } from 'react';
import { ArrowBendUpRight, Export, LinkSimple } from '@phosphor-icons/react';

export function videoShareUrl(bvid: string, page = 1) {
  const url = new URL(`https://www.bilibili.com/video/${encodeURIComponent(bvid)}/`);
  if (Number.isSafeInteger(page) && page > 1) url.searchParams.set('p', String(page));
  return url.href;
}

export function formatEngagementCount(count?: number) {
  if (count === undefined) return undefined;
  if (count < 10_000) return String(count);
  return `${new Intl.NumberFormat('zh-CN', { maximumFractionDigits: 1 }).format(count / 10_000)}万`;
}

export function ShareVideo({ bvid, title, page, shares }: { bvid: string; title: string; page: number; shares?: number }) {
  const [open, setOpen] = useState(false);
  const [message, setMessage] = useState(''), [error, setError] = useState('');
  const [sharing, setSharing] = useState(false), [manualCopy, setManualCopy] = useState(false);
  const dialog = useRef<HTMLDialogElement>(null), link = useRef<HTMLTextAreaElement>(null), trigger = useRef<HTMLButtonElement>(null);
  const url = videoShareUrl(bvid, page);
  const copyText = `${title}\n${url}`;
  const canShare = typeof navigator !== 'undefined' && typeof navigator.share === 'function';
  useEffect(() => {
    if (!open || !dialog.current) return;
    const current = dialog.current; current.showModal();
    return () => { if (current.open) current.close(); trigger.current?.focus({ preventScroll: true }); };
  }, [open]);
  useEffect(() => { if (manualCopy) { link.current?.focus(); link.current?.select(); } }, [manualCopy]);
  useEffect(() => {
    if (!message) return;
    const timer = window.setTimeout(() => setMessage(''), 2000);
    return () => window.clearTimeout(timer);
  }, [message]);
  async function copy() {
    setError(''); setMessage(''); setManualCopy(false);
    try { await navigator.clipboard.writeText(copyText); setOpen(false); setMessage('链接已复制'); }
    catch { setManualCopy(true); setError('无法自动复制，请手动复制下方内容。'); }
  }
  async function share() {
    if (!canShare || sharing) return;
    setSharing(true); setError(''); setMessage(''); setManualCopy(false); setOpen(false);
    try { await navigator.share({ title, text: title, url }); }
    catch (error) {
      if (!(error instanceof Error && error.name === 'AbortError')) { setOpen(true); setError('系统分享未能打开，请复制链接。'); }
    } finally { setSharing(false); }
  }
  return <>
    <button ref={trigger} type="button" className="engagement-button share-video-button" aria-label="转发" aria-haspopup="dialog" title={shares === undefined ? "转发视频" : `转发视频（${shares}）`} onClick={() => { setOpen(true); setError(''); setMessage(''); setManualCopy(false); }}><span className="engagement-icon"><ArrowBendUpRight size={24} weight="fill" /></span><span>{formatEngagementCount(shares) ?? "转发"}</span></button>
    {open && <dialog ref={dialog} className="share-video-dialog" aria-label="分享视频" onCancel={event => { event.preventDefault(); setOpen(false); }} onClick={event => { if (event.target === event.currentTarget) setOpen(false); }}>
      <div className="share-video-options">
        <button type="button" className="share-option" autoFocus onClick={() => void copy()}><span className="share-option-icon"><LinkSimple size={22} /></span><span>复制链接</span></button>
        <button type="button" className="share-option" disabled={!canShare || sharing} onClick={() => void share()}><span className="share-option-icon"><Export size={22} /></span><span>系统分享</span></button>
      </div>
      {!canShare && <p className="share-sheet-hint">当前浏览器不支持系统分享，请复制链接。</p>}
      {error && <div className="share-sheet-error"><p role="alert">{error}</p>{manualCopy && <textarea ref={link} aria-label="视频标题和链接" rows={3} readOnly value={copyText} onFocus={event => event.currentTarget.select()} />}</div>}
      <button type="button" className="share-sheet-cancel" onClick={() => setOpen(false)}>取消</button>
    </dialog>}
    {message && <div className="share-copy-toast" role="status">{message}</div>}
  </>;
}
