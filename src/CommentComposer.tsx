import { useEffect, useRef, useState, type FormEvent } from 'react';
import { UserCircle } from '@phosphor-icons/react';
import type { AuthState, Comment, CommentSubmission, User } from '../shared/types';
import { api, errorMessage, isAbort } from './api';
import { commentParts, mentionAt } from './commentMentions';

export interface CommentAccess {
  auth: AuthState | null;
  onLogin: () => void;
}

const limit = 1000;

export function CommentComposer({ endpoint, access, candidates, reply, onSent, onCancel, onBusyChange }: {
  endpoint: string;
  access: CommentAccess;
  candidates: User[];
  reply?: { root: string; parent: Comment };
  onSent: (comment: Comment) => void;
  onCancel?: () => void;
  onBusyChange?: (busy: boolean) => void;
}) {
  const [draft, setDraft] = useState('');
  const [selected, setSelected] = useState<User[]>([]);
  const [mention, setMention] = useState<ReturnType<typeof mentionAt>>(null);
  const [results, setResults] = useState<{ query: string; items: User[]; error?: string }>();
  const [failure, setFailure] = useState('');
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLTextAreaElement>(null);
  const composing = useRef(false);
  const request = useRef<AbortController | null>(null);
  const query = mention?.query;
  const nearby = [...new Map(candidates.map(user => [user.mid, user])).values()].slice(0, 8);
  const remote = results?.query === query ? results : undefined;
  const matches = query === '' && !remote?.items.length ? nearby : remote?.items;
  useEffect(() => () => request.current?.abort(), []);
  useEffect(() => {
    if (query === undefined || !access.auth?.authenticated) return;
    const controller = new AbortController();
    const delay = setTimeout(() => {
      void api<{ items: User[] }>(`${endpoint}/mention-users?q=${encodeURIComponent(query)}`, { signal: controller.signal })
        .then(result => { if (!controller.signal.aborted) setResults({ query, items: result.items }); })
        .catch(error => { if (!controller.signal.aborted && !isAbort(error)) setResults({ query, items: [], error: errorMessage(error) }); });
    }, 250);
    return () => { clearTimeout(delay); controller.abort(); };
  }, [access.auth?.authenticated, endpoint, query]);

  function updateDraft(value: string, start: number, end: number) {
    setDraft(value);
    if (composing.current) return;
    setSelected(users => {
      const present = new Set(commentParts(value, users).flatMap(part => part.user ? [part.user.mid] : []));
      return users.filter(user => present.has(user.mid));
    });
    setMention(mentionAt(value, start, end));
  }

  function insert(value: string, start: number, end: number) {
    const next = draft.slice(0, start) + value + draft.slice(end);
    if (next.length > limit) return false;
    const caret = start + value.length;
    updateDraft(next, caret, caret);
    requestAnimationFrame(() => {
      input.current?.focus();
      input.current?.setSelectionRange(caret, caret);
    });
    return true;
  }

  function choose(user: User) {
    if (!mention || !insert(`@${user.name} `, mention.start, mention.end)) return;
    setSelected(users => [...users.filter(item => item.mid !== user.mid), user]);
    setMention(null);
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    const text = draft.trim();
    const account = access.auth?.user;
    if (!text || !account || request.current) return;
    const controller = new AbortController();
    request.current = controller;
    setBusy(true); onBusyChange?.(true); setFailure(''); setMention(null);
    const mentions = [...new Map(commentParts(text, selected).flatMap(part => part.user ? [[part.user.mid, { mid: part.user.mid, name: part.user.name }] as const] : [])).values()];
    try {
      const comment = await api<Comment>(endpoint, {
        method: 'POST', signal: controller.signal,
        body: { text, mentions, accountMid: account.mid, ...(reply && { root: reply.root, parent: reply.parent.id }) } satisfies CommentSubmission,
      });
      if (controller.signal.aborted) return;
      setDraft(''); setSelected([]); onSent(comment);
    } catch (error) {
      if (!controller.signal.aborted && !isAbort(error)) setFailure(errorMessage(error));
    } finally {
      if (request.current === controller) request.current = null;
      if (!controller.signal.aborted) { setBusy(false); onBusyChange?.(false); }
    }
  }

  const label = reply ? `回复 ${reply.parent.user.name}` : '写评论';
  if (!access.auth?.authenticated || !access.auth.user) return <div className="comment-composer">
    <UserCircle className="comment-composer-avatar" size={38} aria-hidden="true" />
    <div className="comment-composer-guest"><button type="button" className="button button-primary" disabled={!access.auth} onClick={access.onLogin}>登录</button><span>后发表评论</span></div>
  </div>;

  return <form className="comment-composer" onSubmit={submit} onBlur={event => {
    if (!event.currentTarget.contains(event.relatedTarget)) setMention(null);
  }}>
    {access.auth.user?.avatar ? <img className="comment-composer-avatar" src={access.auth.user.avatar} alt="" referrerPolicy="no-referrer" /> : <UserCircle className="comment-composer-avatar" size={38} aria-hidden="true" />}
    <div className="comment-editor">
      <textarea ref={input} aria-label={label} rows={2} maxLength={limit} autoFocus={Boolean(reply)} value={draft} readOnly={busy} placeholder={reply ? label : '发一条友善的评论'}
        onChange={event => updateDraft(event.target.value, event.target.selectionStart, event.target.selectionEnd)}
        onCompositionStart={() => { composing.current = true; setMention(null); }}
        onCompositionEnd={event => {
          composing.current = false;
          const field = event.currentTarget;
          updateDraft(field.value, field.selectionStart, field.selectionEnd);
        }}
        onSelect={event => {
          const field = event.currentTarget;
          if (!busy && !composing.current) setMention(mentionAt(field.value, field.selectionStart, field.selectionEnd));
        }}
        onKeyDown={event => { if (mention && event.key === 'Escape') { event.preventDefault(); setMention(null); } }} />
      <div className="comment-composer-submit">
        <span>{draft.length}/{limit}</span>
        {onCancel && <button type="button" className="button button-quiet" disabled={busy} onClick={onCancel}>取消</button>}
        <button type="submit" className="button button-primary" disabled={busy || !draft.trim()}>{busy ? '发送中…' : reply ? '回复' : '发布'}</button>
      </div>
      {mention && <div className="comment-mention-results" role="group" aria-label="@ 用户建议">
        {remote?.error && <p role="alert">{remote.error}</p>}
        {matches?.length ? matches.map(user => <button type="button" key={user.mid} onPointerDown={event => event.preventDefault()} onClick={() => choose(user)}>
          {user.avatar && <img src={user.avatar} alt="" loading="lazy" referrerPolicy="no-referrer" />}
          {user.name}
        </button>) : !remote?.error && <p role="status">{query === '' ? '输入用户名搜索' : matches ? '没有匹配的用户' : '正在搜索用户…'}</p>}
      </div>}
      {failure && <p className="comment-write-error" role="alert">{failure}</p>}
    </div>
  </form>;
}
