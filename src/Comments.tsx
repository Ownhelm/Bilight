import { useCallback, useEffect, useState, useSyncExternalStore, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { CaretDown, ChatCircle, ThumbsUp } from '@phosphor-icons/react';
import type { Comment, CommentReplyPage, DynamicLikeState, Page } from '../shared/types';
import { api, errorMessage, isAbort } from './api';
import { CommentComposer, type CommentAccess } from './CommentComposer';
import { commentParts } from './commentMentions';
import { countLabel, dateLabel, Failure, Loading, Pagination, useResource } from './components';
import { LikeStore } from './likeStore';

const videoCommentsExpansionKey = 'bilight:video-comments-expanded';
const commentLikePath = (endpoint: string, id: string) => `${endpoint}/${encodeURIComponent(id)}/like`;

export class CommentLikes extends LikeStore {
  constructor(accountMid: number | undefined) {
    super((url, liked, signal) => api<DynamicLikeState>(url, {
      method: 'POST', body: { liked, accountMid }, signal, keepalive: true,
    }));
  }

  ingestComments(endpoint: string, comments: Comment[], version: number) {
    const { states } = this.getSnapshot();
    for (const comment of comments) {
      const url = commentLikePath(endpoint, comment.id);
      if (states[url] && typeof comment.liked === 'boolean') this.ingest(url, { liked: comment.liked, likes: comment.likes }, version);
    }
  }
}

function storedVideoCommentsExpanded() {
  try { return localStorage.getItem(videoCommentsExpansionKey) !== 'false'; }
  catch { return true; }
}

export function Comments({ endpoint, access, likes, rememberExpansion = false }: { endpoint: string; access: CommentAccess; likes: CommentLikes; rememberExpansion?: boolean }) {
  const [expanded, setExpanded] = useState(() => !rememberExpansion || storedVideoCommentsExpanded());
  const [page, setPage] = useState(1), [refresh, setRefresh] = useState(0), [cursors, setCursors] = useState(['']);
  const [posted, setPosted] = useState<Comment[]>([]);
  const observeLikes = useCallback(() => {
    const version = likes.readVersion();
    return ({ items }: Page<Comment>) => likes.ingestComments(endpoint, items, version);
  }, [endpoint, likes]);
  const { data, error, loading } = useResource<Page<Comment>>(`${endpoint}?page=${page}${cursors[page - 1] ? `&cursor=${encodeURIComponent(cursors[page - 1])}` : ''}`, refresh, observeLikes);
  const newComments = page === 1 ? posted : [];
  const items = [...newComments, ...(data?.items ?? []).filter(comment => !newComments.some(item => item.id === comment.id))];

  function change(next: number) {
    if (next > page && data?.nextCursor) setCursors(value => [...value.slice(0, page), data.nextCursor!]);
    setPage(next);
  }

  function toggle() {
    const next = !expanded;
    setExpanded(next);
    if (rememberExpansion) {
      try { localStorage.setItem(videoCommentsExpansionKey, String(next)); }
      catch { /* The current page remains usable when browser storage is unavailable. */ }
    }
  }

  return <section className="comments-section">
    <button type="button" className="comments-trigger" aria-expanded={expanded} onClick={toggle}>
      <span><ChatCircle size={21} />评论</span><span>{expanded ? '收起评论' : '展开查看'}<CaretDown className={expanded ? 'rotate' : ''} size={16} /></span>
    </button>
    <div className="comments-content" hidden={!expanded}>
      <CommentComposer endpoint={endpoint} access={access} candidates={items.map(comment => comment.user)} onSent={comment => {
        setPosted(current => [comment, ...current.filter(item => item.id !== comment.id)]);
        setPage(1);
      }} />
      {items.map(comment => <CommentThread key={`${page}:${comment.id}`} endpoint={endpoint} comment={comment} access={access} likes={likes} />)}
      {loading ? <Loading text="正在加载评论" /> : error ? <Failure error={error} retry={() => setRefresh(value => value + 1)} /> : !items.length && <p className="comments-empty">暂时没有评论。</p>}
      {data && <Pagination page={page} hasMore={data.hasMore && Boolean(data.nextCursor)} onChange={change} />}
    </div>
  </section>;
}

function CommentThread({ endpoint, comment, access, likes }: { endpoint: string; comment: Comment; access?: CommentAccess; likes: CommentLikes }) {
  const [expanded, setExpanded] = useState(false), [items, setItems] = useState<Comment[]>([]), [page, setPage] = useState(1), [loadedPage, setLoadedPage] = useState(0);
  const [total, setTotal] = useState(comment.replyCount ?? 0), [more, setMore] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState(''), [retry, setRetry] = useState(0);
  const [posted, setPosted] = useState<Comment[]>([]);
  const [target, setTarget] = useState<Comment>();
  const [replySending, setReplySending] = useState(false);
  const replies = [...items, ...posted.filter(reply => !items.some(item => item.id === reply.id))];
  const candidates = [comment.user, ...replies.map(reply => reply.user)];

  useEffect(() => {
    if (!expanded || loadedPage >= page) { setBusy(false); return; }
    const controller = new AbortController(), version = likes.readVersion();
    setBusy(true); setError('');
    void api<CommentReplyPage>(`${endpoint}/${encodeURIComponent(comment.id)}/replies?page=${page}`, { signal: controller.signal }).then(result => {
      if (controller.signal.aborted) return;
      const seen = new Set(items.map(item => item.id)), additions = result.items.filter(item => !seen.has(item.id) && Boolean(seen.add(item.id)));
      if (result.hasMore && !additions.length) throw new Error('回复分页没有新增内容，请重试。');
      likes.ingestComments(endpoint, additions, version);
      setItems(current => [...current, ...additions]);
      setTotal(current => Math.max(current, result.total)); setMore(result.hasMore); setLoadedPage(page);
    }).catch(error => { if (!isAbort(error) && !controller.signal.aborted) setError(errorMessage(error)); })
      .finally(() => { if (!controller.signal.aborted) setBusy(false); });
    return () => controller.abort();
  // Items and loadedPage belong to the page request; changing them must not start another fetch.
  }, [endpoint, comment.id, expanded, page, retry, likes]);

  function replyTo(row: Comment) {
    if (replySending) return;
    if (!access?.auth?.authenticated || !access.auth.user) { access?.onLogin(); return; }
    setTarget(row);
  }

  function composer(row: Comment) {
    if (!access || target?.id !== row.id) return null;
    return <CommentComposer key={row.id} endpoint={endpoint} access={access} candidates={[row.user, ...candidates]}
      reply={{ root: comment.id, parent: row }} onCancel={() => setTarget(undefined)} onBusyChange={setReplySending}
      onSent={value => {
        setPosted(current => [...current.filter(item => item.id !== value.id), value]);
        setTotal(current => current + 1);
        setTarget(undefined); setExpanded(true);
      }} />;
  }

  return <CommentItem endpoint={endpoint} comment={comment} access={access} likes={likes} replySending={replySending} onReply={() => replyTo(comment)}>
    {composer(comment)}
    {total > 0 && <>
      <div className="comment-reply-toggle"><span>共{total}条回复</span><button type="button" aria-expanded={expanded} aria-controls={`replies-${comment.id}`} onClick={() => setExpanded(value => !value)}>{expanded ? '收起' : '展开'}</button></div>
      <div hidden={!expanded} id={`replies-${comment.id}`} className="comment-thread">
        {replies.map(row => <CommentItem key={row.id} endpoint={endpoint} comment={row} access={access} likes={likes} replySending={replySending} onReply={() => replyTo(row)} reply>{composer(row)}</CommentItem>)}
        {busy && <p className="comment-reply-status" role="status">正在读取回复…</p>}
        {error && <div className="comment-reply-error"><p role="alert">{error}</p><button type="button" onClick={() => setRetry(value => value + 1)}>重试</button></div>}
        {!busy && !error && loadedPage > 0 && !replies.length && <p className="comment-reply-status">暂时没有可见回复。</p>}
        {!busy && !error && more && <button type="button" className="comment-reply-more" onClick={() => setPage(loadedPage + 1)}>加载更多</button>}
      </div>
    </>}
  </CommentItem>;
}

function CommentItem({ endpoint, comment, access, likes, onReply, replySending, reply = false, children }: {
  endpoint: string;
  comment: Comment;
  access?: CommentAccess;
  likes: CommentLikes;
  onReply: () => void;
  replySending: boolean;
  reply?: boolean;
  children?: ReactNode;
}) {
  const path = commentLikePath(endpoint, comment.id);
  const snapshot = useSyncExternalStore(likes.subscribe, likes.getSnapshot);
  const pending = snapshot.pending[path], failure = snapshot.errors[path];
  const state = pending ?? snapshot.states[path] ?? { liked: Boolean(comment.liked), likes: comment.likes };

  function like() {
    if (!access?.auth?.authenticated || !access.auth.user) { access?.onLogin(); return; }
    likes.toggle(path, state);
  }

  return <article className={`comment${reply ? ' comment-reply' : ''}`}>
    <Link to={`/creator/${comment.user.mid}`} className="comment-avatar" aria-label={comment.user.name}><img src={comment.user.avatar} alt="" loading="lazy" referrerPolicy="no-referrer" /></Link>
    <div className="comment-body">
      <Link className="comment-name" to={`/creator/${comment.user.mid}`}>{comment.user.name}</Link>
      <p>{commentParts(comment.text, comment.mentions ?? [], comment.emotes).map((part, index) => {
        if (part.user) return <Link className="comment-at" key={index} to={`/creator/${part.user.mid}`}>{part.text}</Link>;
        return part.emote ? <CommentEmote key={`${index}:${part.emote}`} token={part.text} url={part.emote} /> : part.text;
      })}</p>
      <div className="comment-meta">
        <span>{dateLabel(comment.createdAt)}</span>
        {access ? <>
          <button type="button" className="comment-like" aria-label={state.liked ? '取消评论点赞' : '点赞评论'} aria-pressed={state.liked} aria-busy={Boolean(pending)} disabled={!access.auth} onClick={like}>
            <ThumbsUp size={17} weight={state.liked ? 'fill' : 'regular'} /><span>{state.likes.toLocaleString('zh-CN')}</span>
          </button>
          <button type="button" disabled={!access.auth || replySending} onClick={onReply}>回复</button>
        </> : state.likes > 0 && <span>{countLabel(state.likes)} 赞</span>}
      </div>
      {failure && <p className="comment-write-error" role="alert">{failure}</p>}
      {children}
    </div>
  </article>;
}

function CommentEmote({ token, url }: { token: string; url: string }) {
  const [failed, setFailed] = useState(false);
  return failed ? token : <img className="comment-emote" src={url} alt={token} loading="lazy" onError={() => setFailed(true)} />;
}
