import { useEffect, useState, useSyncExternalStore } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ChatCircle, ThumbsUp } from '@phosphor-icons/react';
import type { AuthState, DynamicLikeState, VideoDynamic } from '../shared/types';
import { api, errorMessage, isAbort } from './api';
import { countLabel, dateLabel, Failure, Loading, VideoGrid } from './components';
import { Comments } from './Comments';

import { DynamicLikes } from './dynamicLikes';
export { DynamicLikes } from './dynamicLikes';

export function DynamicActions({ id, initial, comments, store, auth, onLogin, detail = false }: { id: string; initial: DynamicLikeState; comments: number; store: DynamicLikes; auth: AuthState | null; onLogin: () => void; detail?: boolean }) {
  const [failure, setFailure] = useState('');
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot), state = snapshot.states[id] ?? initial;
  const pending = Object.hasOwn(snapshot.pending, id), selected = pending ? snapshot.pending[id] : state.liked;
  return <div className="following-dynamic-actions">
    {detail ? <a href="#dynamic-comments"><ChatCircle size={16} />{countLabel(comments)} 评论</a> : <Link to={`/dynamic/${id}`} aria-label="查看视频动态"><ChatCircle size={16} />查看动态{comments > 0 ? ` · ${countLabel(comments)}` : ''}</Link>}
    <button type="button" aria-label={selected ? '取消动态点赞' : '点赞动态'} aria-pressed={selected} aria-busy={pending} disabled={pending || !auth} className={selected ? 'selected' : ''} onClick={() => { if (!auth?.authenticated) { onLogin(); return; } setFailure(''); void store.toggle(id, initial).catch(error => { if (!isAbort(error)) setFailure(errorMessage(error)); }); }}>
      <ThumbsUp size={16} weight={selected ? 'fill' : 'regular'} /><span>{state.likes > 0 ? countLabel(state.likes) : '赞'}</span>
    </button>{failure && <span className="dynamic-like-error" role="alert">{failure}</span>}
  </div>;
}

export function DynamicDetail({ store, auth, onLogin }: { store: DynamicLikes; auth: AuthState | null; onLogin: () => void }) {
  const { id = '' } = useParams();
  const [post, setPost] = useState<VideoDynamic | null>(null), [error, setError] = useState(''), [busy, setBusy] = useState(true), [retry, setRetry] = useState(0);
  useEffect(() => {
    document.title = '动态详情 · Bilight';
    const controller = new AbortController(), version = store.readVersion();
    setBusy(true); setError('');
    void api<VideoDynamic>(`/api/dynamics/${encodeURIComponent(id)}`, { signal: controller.signal }).then(value => {
      if (controller.signal.aborted) return;
      setPost(value); store.ingest(value.id, { liked: value.liked, likes: value.likes }, version);
    }).catch(error => { if (!isAbort(error) && !controller.signal.aborted) setError(errorMessage(error)); }).finally(() => { if (!controller.signal.aborted) setBusy(false); });
    return () => controller.abort();
  }, [id, store, retry]);
  return <div className="page-container dynamic-detail-page"><div className="page-heading"><h1>动态详情</h1></div>
    {post && <><div className="dynamic-detail-author"><Link to={`/creator/${post.author.mid}`}><img src={post.author.avatar} alt="" referrerPolicy="no-referrer" />{post.author.name}</Link><span>{dateLabel(post.publishedAt)} {post.action}</span></div>
      {post.text && <p className="dynamic-detail-text">{post.text}</p>}
      <div className="dynamic-detail-video"><VideoGrid videos={[post.video]} /></div>
      <DynamicActions id={post.id} initial={{ liked: post.liked, likes: post.likes }} comments={post.comments} store={store} auth={auth} onLogin={onLogin} detail />
      <div id="dynamic-comments"><Comments key={post.id} bvid={post.video.bvid} /></div>
    </>}
    {busy && <Loading text="正在读取动态" />}{error && <Failure error={new Error(error)} retry={() => setRetry(value => value + 1)} />}
  </div>;
}
