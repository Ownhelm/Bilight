import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { CaretDown, ChatCircle } from '@phosphor-icons/react';
import type { Comment, CommentReplyPage, Page } from '../shared/types';
import { api, errorMessage, isAbort } from './api';
import { countLabel, dateLabel, Failure, Loading, Pagination, useResource } from './components';

export function Comments({ bvid }: { bvid: string }) {
  const [expanded, setExpanded] = useState(true), [page, setPage] = useState(1), [refresh, setRefresh] = useState(0), [cursors, setCursors] = useState(['']);
  const { data, error, loading } = useResource<Page<Comment>>(expanded ? `/api/videos/${bvid}/comments?page=${page}${cursors[page - 1] ? `&cursor=${encodeURIComponent(cursors[page - 1])}` : ''}` : null, refresh);
  function change(next: number) {
    if (next > page && data?.nextCursor) setCursors(value => [...value.slice(0, page), data.nextCursor!]);
    setPage(next);
  }
  return <section className="comments-section"><button className="comments-trigger" aria-expanded={expanded} onClick={() => setExpanded(value => !value)}><span><ChatCircle size={21} />评论</span><span>{expanded ? '收起评论' : '展开查看'}<CaretDown className={expanded ? 'rotate' : ''} size={16} /></span></button>
    {expanded && <div className="comments-content"><p className="comments-note">按时间查看评论，仅阅读。</p>{loading ? <Loading text="正在加载评论" /> : error ? <Failure error={error} retry={() => setRefresh(value => value + 1)} /> : data?.items.length ? data.items.map(comment => <CommentItem key={`${page}:${comment.id}`} bvid={bvid} comment={comment} />) : <p className="comments-empty">暂时没有评论。</p>}{data && <Pagination page={page} hasMore={data.hasMore && Boolean(data.nextCursor)} onChange={change} />}</div>}
  </section>;
}

export function CommentItem({ bvid, comment, reply = false }: { bvid: string; comment: Comment; reply?: boolean }) {
  const [expanded, setExpanded] = useState(false), [items, setItems] = useState<Comment[]>([]), [page, setPage] = useState(1), [loadedPage, setLoadedPage] = useState(0);
  const [total, setTotal] = useState(comment.replyCount ?? 0), [more, setMore] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState(''), [retry, setRetry] = useState(0);
  useEffect(() => {
    if (!expanded || loadedPage >= page) { setBusy(false); return; }
    const controller = new AbortController();
    setBusy(true); setError('');
    void api<CommentReplyPage>(`/api/videos/${bvid}/comments/${encodeURIComponent(comment.id)}/replies?page=${page}`, { signal: controller.signal }).then(result => {
      if (controller.signal.aborted) return;
      const seen = new Set(items.map(item => item.id)), additions = result.items.filter(item => !seen.has(item.id) && Boolean(seen.add(item.id)));
      if (result.hasMore && !additions.length) throw new Error('回复分页没有新增内容，请重试。');
      setItems(current => [...current, ...additions]); setTotal(result.total); setMore(result.hasMore); setLoadedPage(page);
    }).catch(error => { if (!isAbort(error) && !controller.signal.aborted) setError(errorMessage(error)); })
      .finally(() => { if (!controller.signal.aborted) setBusy(false); });
    return () => controller.abort();
  // Items and loadedPage belong to the page request; changing them must not start another fetch.
  }, [bvid, comment.id, expanded, page, retry]);
  return <article className={`comment${reply ? ' comment-reply' : ''}`}>
    <Link to={`/creator/${comment.user.mid}`} className="comment-avatar"><img src={comment.user.avatar} alt="" loading="lazy" referrerPolicy="no-referrer" /></Link>
    <div className="comment-body"><Link className="comment-name" to={`/creator/${comment.user.mid}`}>{comment.user.name}</Link><p>{comment.text}</p>
      <div className="comment-meta"><span>{dateLabel(comment.createdAt)}</span>{comment.likes > 0 && <span>{countLabel(comment.likes)} 赞</span>}</div>
      {!reply && (comment.replyCount ?? 0) > 0 && <>
        <div className="comment-reply-toggle"><span>共{total}条回复</span><button type="button" aria-expanded={expanded} aria-controls={`replies-${comment.id}`} onClick={() => setExpanded(value => !value)}>{expanded ? '收起' : '展开'}</button></div>
        {expanded && <div id={`replies-${comment.id}`} className="comment-thread">
          {items.map(item => <CommentItem key={item.id} bvid={bvid} comment={item} reply />)}
          {busy && <p className="comment-reply-status" role="status">正在读取回复…</p>}
          {error && <div className="comment-reply-error"><p role="alert">{error}</p><button type="button" onClick={() => setRetry(value => value + 1)}>重试</button></div>}
          {!busy && !error && loadedPage > 0 && !items.length && <p className="comment-reply-status">暂时没有可见回复。</p>}
          {!busy && !error && more && <button type="button" className="comment-reply-more" onClick={() => setPage(loadedPage + 1)}>加载更多</button>}
        </div>}
      </>}
    </div>
  </article>;
}
