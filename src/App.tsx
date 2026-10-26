import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { Link, NavLink, Route, Routes, useLocation, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { ArrowClockwise, ArrowDown, ArrowLeft, ArrowRight, Bell, CaretDown, ChatCircle, Check, SignOut, UserCircle, Users } from '@phosphor-icons/react';
import type { AuthState, Comment, CreatorSummary, Page, SearchPage, VideoDetail, VideoSummary } from '../shared/types';
import { api, errorMessage, isAbort } from './api';
import { countLabel, dateLabel, duration, Empty, Failure, Loading, Pagination, SearchBox, useResource, VideoGrid } from './components';
import { Login } from './Login';
import { preloadPlayer, VideoPlayer } from './Player';
import { TripleActions } from './TripleActions';
import { HistoryMenu, HistoryPage } from './History';
import { CreatorCollections, CreatorCollectionVideos } from './CreatorCollections';
import { completeFollowingRows, FollowingFeed, useFollowingColumns, useFollowingFeed } from './following';
import playbackMark from '../branding/playback-mark.svg?no-inline';

export function App() {
  const location = useLocation();
  const [auth, setAuth] = useState<AuthState | null>(null);
  const [authError, setAuthError] = useState('');
  const [loginOpen, setLoginOpen] = useState(false);
  const [authGeneration, setAuthGeneration] = useState(0);
  const [loggingOut, setLoggingOut] = useState(false);
  const followingCache = useMemo(() => new FollowingFeed(), [auth?.user?.mid, authGeneration]);
  useEffect(() => () => followingCache.clear(), [followingCache]);
  const refreshAuth = useCallback(async () => {
    const state = await api<AuthState>('/api/auth/state'); setAuth(state); setAuthError('');
    if (state.authenticated) { setLoginOpen(false); setAuthGeneration(value => value + 1); }
  }, []);
  useEffect(() => {
    const controller = new AbortController();
    api<AuthState>('/api/auth/state', { signal: controller.signal }).then(state => { if (!controller.signal.aborted) setAuth(state); }).catch(error => { if (!isAbort(error)) { setAuth({ authenticated: false }); setAuthError(errorMessage(error)); } });
    const expired = () => { setAuth({ authenticated: false, needsLogin: true, message: '登录已失效，请重新登录。' }); setAuthGeneration(value => value + 1); };
    window.addEventListener('bilight:session-expired', expired);
    return () => { controller.abort(); window.removeEventListener('bilight:session-expired', expired); };
  }, []);
  useEffect(() => { if (location.pathname !== '/following') window.scrollTo({ top: 0 }); }, [location.pathname, location.search]);
  useEffect(() => {
    const previous = history.scrollRestoration; history.scrollRestoration = 'manual';
    return () => { history.scrollRestoration = previous; };
  }, []);
  async function logout() {
    if (loggingOut) return; setLoggingOut(true);
    try { await api('/api/auth/logout', { method: 'POST' }); setAuth({ authenticated: false }); setAuthGeneration(value => value + 1); }
    catch (error) { setAuthError(errorMessage(error)); }
    finally { setLoggingOut(false); }
  }
  const isHome = location.pathname === '/';
  return <><a className="skip-link" href="#main-content">跳到主要内容</a><header className={`site-header${isHome ? ' home-header' : ''}`}>
    <Link className="brand" to="/" aria-label="Bilight 首页"><img src={playbackMark} aria-hidden="true" alt="" width="31" height="31" /><span>bilight</span></Link>
    {!isHome && <div className="header-search"><SearchBox initial={location.pathname === '/search' ? new URLSearchParams(location.search).get('keyword') ?? '' : ''} /></div>}
    <nav className="header-nav" aria-label="主导航"><NavLink className="following-link" to="/following"><Bell size={21} /><span>关注</span></NavLink><HistoryMenu key={`${auth?.user?.mid ?? 'anonymous'}:${authGeneration}`} auth={auth} onLogin={() => setLoginOpen(true)} />
      {auth?.authenticated && auth.user ? <details className="account-menu"><summary aria-label={`账号：${auth.user.name}`}><img src={auth.user.avatar} alt="" referrerPolicy="no-referrer" /><CaretDown size={12} /></summary><div className="account-popover"><p>{auth.user.name}</p><span className="account-connected"><Check size={13} />账号已连接</span><button onClick={() => void logout()} disabled={loggingOut}><SignOut size={16} />{loggingOut ? '正在退出' : '退出登录'}</button></div></details> : <button className="login-button" disabled={!auth} onClick={() => setLoginOpen(true)}><UserCircle size={21} /><span>登录</span></button>}
    </nav>
  </header>
    {(auth?.needsLogin || authError) && <div className="session-notice" role="status"><span>{authError || auth?.message || '登录已失效，请重新登录。'}</span><button onClick={() => authError ? void refreshAuth().catch(error => setAuthError(errorMessage(error))) : setLoginOpen(true)}>{authError ? '重试连接' : '重新登录'}</button><button className="notice-close" aria-label="关闭提示" onClick={() => { setAuthError(''); setAuth(state => state ? { ...state, needsLogin: false } : state); }}>×</button></div>}
    <main id="main-content"><Routes>
      <Route path="/" element={<Home />} />
      <Route path="/search" element={<Search />} />
      <Route path="/following" element={<Following key={`${auth?.user?.mid ?? 'anonymous'}:${authGeneration}`} cache={followingCache} auth={auth} onLogin={() => setLoginOpen(true)} />} />
      <Route path="/history" element={<HistoryPage key={`${auth?.user?.mid ?? 'anonymous'}:${authGeneration}:${location.search}`} auth={auth} onLogin={() => setLoginOpen(true)} />} />
      <Route path="/creator/:mid" element={<Creator />} />
      <Route path="/creator/:mid/collections/:kind/:collectionId" element={<Creator />} />
      <Route path="/video/:bvid" element={<Video key={location.pathname} auth={auth} authGeneration={authGeneration} onLogin={() => setLoginOpen(true)} />} />
      <Route path="/open/*" element={<OpenLink />} />
      <Route path="*" element={<div className="page-container"><Empty title="这个页面还不存在" action={<Link className="button button-primary" to="/">返回首页</Link>}>从搜索开始，找到想看的内容。</Empty></div>} />
    </Routes></main>
    {loginOpen && <Login onClose={() => setLoginOpen(false)} onSuccess={refreshAuth} />}
  </>;
}

function Home() {
  useEffect(() => { document.title = 'Bilight · 只看想看的'; }, []);
  return <div className="home-page"><section className="home-search" aria-labelledby="home-title"><span className="home-kicker">你的哔哩哔哩，清爽一点。</span><h1 id="home-title">只看<span>想看的。</span></h1><SearchBox large /><p className="home-footnote">没有推荐，从你想看的内容开始。</p></section><footer className="home-footer"><span className="focus-mark" aria-hidden="true"><Check size={12} weight="bold" /></span>搜索与关注，由你选择。</footer></div>;
}

function Search() {
  const [params, setParams] = useSearchParams();
  const keyword = params.get('keyword') ?? params.get('q') ?? '';
  const type = params.get('type') === 'user' ? 'user' : 'video';
  const page = positivePage(params.get('page'));
  const [refresh, setRefresh] = useState(0);
  const { data, error, loading } = useResource<SearchPage>(keyword ? `/api/search?keyword=${encodeURIComponent(keyword)}&type=${type}&page=${page}` : null, refresh);
  useEffect(() => { document.title = keyword ? `${keyword} · 搜索 · Bilight` : '搜索 · Bilight'; }, [keyword]);
  function change(nextType: string, nextPage = 1) { setParams({ keyword, type: nextType, page: String(nextPage) }); }
  return <div className="page-container search-page"><div className="page-heading"><div><p className="section-eyebrow">搜索结果</p><h1>{keyword || '你想看什么？'}</h1></div></div>
    <div className="content-tabs" role="tablist" aria-label="搜索类型"><button role="tab" aria-selected={type === 'video'} className={type === 'video' ? 'active' : ''} onClick={() => change('video')}>视频</button><button role="tab" aria-selected={type === 'user'} className={type === 'user' ? 'active' : ''} onClick={() => change('user')}>UP 主</button></div>
    {!keyword ? <Empty title="输入关键词，开始搜索">也可以直接粘贴 B 站视频链接或 BV 号。</Empty> : loading ? <Loading text="正在搜索" /> : error ? <Failure error={error} retry={() => setRefresh(value => value + 1)} /> : data && (type === 'video' ? data.videos.length ? <VideoGrid videos={data.videos} /> : <Empty title="没有找到相关视频">换个关键词再试试。</Empty> : data.users.length ? <div className="creator-results">{data.users.map(user => <CreatorRow key={user.mid} creator={user} />)}</div> : <Empty title="没有找到相关 UP 主">换个关键词再试试。</Empty>)}
    {data && <Pagination page={page} hasMore={data.hasMore} onChange={next => change(type, next)} />}
  </div>;
}

function Following({ auth, onLogin, cache }: { auth: AuthState | null; onLogin: () => void; cache: FollowingFeed }) {
  const feed = useFollowingFeed(cache, Boolean(auth?.authenticated));
  const restored = useRef(feed.initialized);
  const scrollIntent = useRef(false), nearEnd = useRef(false);
  const columns = useFollowingColumns();
  const videos = completeFollowingRows(feed.items, columns, Boolean(feed.cursor));
  const sentinel = useRef<HTMLDivElement>(null);
  const fillTarget = useRef({ count: 0, attempts: 0 });
  const requestMore = useCallback(() => {
    if (feed.loading || feed.error || !feed.cursor) return;
    fillTarget.current = { count: videos.length + columns, attempts: 1 };
    feed.loadMore();
  }, [feed.loading, feed.error, feed.cursor, feed.loadMore, videos.length, columns]);
  const loadMore = useRef(requestMore); loadMore.current = requestMore;
  useLayoutEffect(() => {
    window.scrollTo({ top: cache.scrollTop, behavior: 'instant' });
    const remember = () => { cache.scrollTop = Math.max(0, window.scrollY); };
    window.addEventListener('scroll', remember, { passive: true });
    return () => { window.removeEventListener('scroll', remember); };
  }, [cache]);
  useEffect(() => { document.title = '我的关注 · Bilight'; }, []);
  useEffect(() => {
    const target = fillTarget.current;
    if (feed.loading || feed.error || !target.count) return;
    if (!feed.cursor || videos.length >= target.count) { target.count = 0; return; }
    // If filtering leaves fewer than one new row, top it up with at most two extra pages.
    if (target.attempts < 3) { target.attempts++; feed.loadMore(); }
  }, [feed.loading, feed.error, feed.cursor, feed.loadMore, videos.length]);
  useEffect(() => {
    if (!auth?.authenticated || !feed.initialized || !sentinel.current || !('IntersectionObserver' in window)) return;
    // Keep one observer: an empty filtered page must not start an unattended fetch loop.
    const observer = new IntersectionObserver(entries => {
      nearEnd.current = entries.some(entry => entry.isIntersecting);
      if (nearEnd.current && (!restored.current || scrollIntent.current)) loadMore.current();
    }, { rootMargin: '0px 0px 240px 0px' });
    observer.observe(sentinel.current);
    return () => observer.disconnect();
  }, [auth?.authenticated, feed.initialized]);
  useEffect(() => {
    const intent = (event: Event) => {
      if (event instanceof WheelEvent && event.deltaY <= 0) return;
      if (event instanceof KeyboardEvent && (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey || !['ArrowDown', 'PageDown', 'End', ' '].includes(event.key) || (event.target as HTMLElement | null)?.closest('input,textarea,select,[contenteditable="true"],[role="dialog"]'))) return;
      scrollIntent.current = true;
      if (nearEnd.current) loadMore.current();
    };
    window.addEventListener('wheel', intent, { passive: true }); window.addEventListener('touchmove', intent, { passive: true }); window.addEventListener('keydown', intent);
    return () => { window.removeEventListener('wheel', intent); window.removeEventListener('touchmove', intent); window.removeEventListener('keydown', intent); };
  }, []);
  return <div className="page-container following-page"><div className="page-heading"><div><p className="section-eyebrow">来自你的选择</p><h1>我的关注</h1></div>{auth?.authenticated && <button className="button button-quiet following-refresh" onClick={() => { fillTarget.current = { count: columns, attempts: 1 }; feed.refresh(); }} disabled={feed.loading}><ArrowClockwise className={feed.loading ? 'spin' : ''} size={16} />刷新最新</button>}</div>
    {auth?.authenticated && <p className="following-description">只看已关注 UP 主的视频，按发布时间更新。向下滚动继续加载。</p>}
    {!auth ? <Loading text="正在连接账号" /> : !auth.authenticated ? <Empty title="看看关注的 UP 主更新了什么" action={<button className="button button-primary" onClick={onLogin}>登录哔哩哔哩</button>}>登录后，只显示你已关注 UP 主的视频。</Empty> : <>
      {!feed.initialized && <div className="following-skeleton" role="status" aria-label="正在获取关注更新"><p>正在获取关注更新</p><div className="video-grid" aria-hidden="true">{Array.from({ length: columns * 2 }, (_, index) => <div className="video-placeholder" key={index}><div /><span /><span /></div>)}</div></div>}
      {videos.length > 0 && <VideoGrid videos={videos} columns={columns} />}
      {feed.error && <Failure error={feed.error} retry={feed.retry} />}
      {feed.initialized && !feed.error && !feed.items.length && !feed.cursor && <Empty title="暂时没有新的视频">你的关注更新会显示在这里。</Empty>}
      <div className="following-loader" ref={sentinel}>
        {feed.initialized && (feed.loading ? <Loading text="正在加载关注更新，已有视频可继续浏览" /> : feed.error ? null : feed.cursor ? <button className="button button-quiet" onClick={requestMore}>加载更多关注视频<ArrowDown size={16} /></button> : feed.items.length > 0 ? <p>已看完当前可获取的关注视频。</p> : null)}
      </div>
    </>}
  </div>;
}

function CreatorRow({ creator }: { creator: CreatorSummary }) {
  return <Link className="creator-row" to={`/creator/${creator.mid}`}><img src={creator.avatar} alt="" referrerPolicy="no-referrer" loading="lazy" /><div><h2>{creator.name}<span className="up-tag">UP</span></h2><p>{creator.description || '这位 UP 主还没有填写简介。'}</p>{creator.fans !== undefined && <span className="creator-fans"><Users size={14} />{countLabel(creator.fans)} 粉丝</span>}</div><ArrowRight className="creator-arrow" size={20} /></Link>;
}

function Creator() {
  const { mid, kind, collectionId } = useParams(); const [params, setParams] = useSearchParams(); const page = positivePage(params.get('page'));
  const [refresh, setRefresh] = useState(0);
  const collections = Boolean(collectionId) || params.get('tab') === 'collections';
  const profile = useResource<CreatorSummary>(`/api/creators/${encodeURIComponent(mid ?? '')}`, refresh);
  const videos = useResource<Page<VideoSummary>>(!collections ? `/api/creators/${encodeURIComponent(mid ?? '')}/videos?page=${page}` : null, refresh);
  useEffect(() => { document.title = `${profile.data?.name ?? 'UP 主'} · Bilight`; }, [profile.data]);
  return <div className="page-container creator-page"><Link className="back-link" to="/following"><ArrowLeft size={16} />返回关注</Link>
    {profile.loading ? <Loading text="正在加载 UP 主信息" /> : profile.error ? <Failure error={profile.error} retry={() => setRefresh(value => value + 1)} /> : profile.data && <section className="creator-profile"><img className="creator-avatar" src={profile.data.avatar} alt="" referrerPolicy="no-referrer" /><div><span className="section-eyebrow">UP 主</span><h1>{profile.data.name}</h1><p>{profile.data.description || '这位 UP 主还没有填写简介。'}</p>{profile.data.fans !== undefined && <span className="creator-fans"><Users size={15} />{countLabel(profile.data.fans)} 粉丝</span>}</div></section>}
    <nav className="content-tabs" aria-label="UP 主主页板块"><Link className={!collections ? 'active' : ''} aria-current={!collections ? 'page' : undefined} to={`/creator/${mid}`}>视频</Link><Link className={collections ? 'active' : ''} aria-current={collections ? 'page' : undefined} to={`/creator/${mid}?tab=collections`}>合集和列表</Link></nav>
    {collectionId ? kind === 'season' || kind === 'series' ? <CreatorCollectionVideos mid={mid ?? ''} kind={kind} id={collectionId} page={page} profile={profile.data} refresh={refresh} onRetry={() => setRefresh(value => value + 1)} onPage={next => setParams({ page: String(next) })} /> : <Empty title="没有这个类型的列表" /> : collections ? <CreatorCollections mid={mid ?? ''} page={page} refresh={refresh} onRetry={() => setRefresh(value => value + 1)} onPage={next => setParams({ tab: 'collections', page: String(next) })} /> : <><div className="list-heading"><h2>视频</h2><span>最新发布</span></div>{videos.loading ? <Loading text="正在获取视频" /> : videos.error ? <Failure error={videos.error} retry={() => setRefresh(value => value + 1)} /> : videos.data?.items.length ? <VideoGrid videos={videos.data.items} /> : <Empty title="暂时没有可显示的视频" />}{videos.data && <Pagination page={page} hasMore={videos.data.hasMore} onChange={next => setParams({ page: String(next) })} />}</>}
  </div>;
}

function Video({ auth, authGeneration, onLogin }: { auth: AuthState | null; authGeneration: number; onLogin: () => void }) {
  useEffect(() => { void preloadPlayer().catch(() => {}); }, []);
  const { bvid } = useParams(); const [params, setParams] = useSearchParams(); const [refresh, setRefresh] = useState(0);
  const { data, error, loading } = useResource<VideoDetail>(`/api/videos/${encodeURIComponent(bvid ?? '')}`, refresh);
  const requestedPart = positivePage(params.get('p')); const part = data?.parts.find(item => item.page === requestedPart) ?? data?.parts[0];
  useEffect(() => { document.title = `${data?.title ?? '视频'} · Bilight`; }, [data]);
  if (loading) return <div className="page-container"><Loading text="正在打开视频" /></div>;
  if (error) return <div className="page-container"><Failure error={error} retry={() => setRefresh(value => value + 1)} /></div>;
  if (!data || !part) return <div className="page-container"><Empty title="这个视频暂时无法播放" /></div>;
  return <div className="page-container watch-page"><div className="watch-title"><h1>{data.title}</h1><p><span>{countLabel(data.views)} 播放</span><span>{dateLabel(data.publishedAt)}</span><span className="watch-bvid">{data.bvid}</span></p></div>
    <div className={`watch-layout${data.parts.length > 1 ? ' has-parts' : ''}`}><div className="watch-primary"><VideoPlayer key={`${data.bvid}:${part.cid}`} bvid={data.bvid} cid={part.cid} poster={data.cover} startTime={Math.max(0, Math.min(part.duration, Number(params.get('t')) || 0))} accountMid={auth?.authenticated ? auth.user?.mid : undefined} />
      <TripleActions key={`${data.bvid}:${auth?.user?.mid ?? 'anonymous'}:${authGeneration}`} bvid={data.bvid} auth={auth} onLogin={onLogin} snapshot={data.interaction} />
      <Link className="watch-creator" to={`/creator/${data.owner.mid}`}><img src={data.owner.avatar} alt="" referrerPolicy="no-referrer" /><div><strong>{data.owner.name}</strong><span>查看 UP 主的视频</span></div><ArrowRight size={18} /></Link>
      {data.description && <details className="video-description"><summary>视频简介<CaretDown size={15} /></summary><p>{data.description}</p></details>}
      <Comments bvid={data.bvid} />
    </div>{data.parts.length > 1 && <aside className="parts-panel" aria-label="视频分P"><div className="parts-heading"><h2>分 P 列表</h2><span>{part.page} / {data.parts.length}</span></div><p className="parts-note">点击切换分 P</p><div className="parts-list">{data.parts.map(item => <button key={item.cid} className={item.cid === part.cid ? 'active' : ''} onClick={() => setParams({ p: String(item.page) })} aria-current={item.cid === part.cid ? 'true' : undefined}><span className="part-number">{String(item.page).padStart(2, '0')}</span><span className="part-title">{item.title}</span><span className="part-duration">{duration(item.duration)}</span></button>)}</div></aside>}</div>
  </div>;
}

function Comments({ bvid }: { bvid: string }) {
  const [expanded, setExpanded] = useState(true); const [page, setPage] = useState(1); const [refresh, setRefresh] = useState(0); const [cursors, setCursors] = useState(['']);
  const { data, error, loading } = useResource<Page<Comment>>(expanded ? `/api/videos/${bvid}/comments?page=${page}${cursors[page - 1] ? `&cursor=${encodeURIComponent(cursors[page - 1])}` : ''}` : null, refresh);
  function change(next: number) {
    if (next > page && data?.nextCursor) setCursors(value => [...value.slice(0, page), data.nextCursor!]);
    setPage(next);
  }
  return <section className="comments-section"><button className="comments-trigger" aria-expanded={expanded} onClick={() => setExpanded(value => !value)}><span><ChatCircle size={21} />评论</span><span>{expanded ? '收起评论' : '展开查看'}<CaretDown className={expanded ? 'rotate' : ''} size={16} /></span></button>
    {expanded && <div className="comments-content"><p className="comments-note">按时间查看评论，仅阅读。</p>{loading ? <Loading text="正在加载评论" /> : error ? <Failure error={error} retry={() => setRefresh(value => value + 1)} /> : data?.items.length ? data.items.map(comment => <CommentItem key={comment.id} comment={comment} />) : <p className="comments-empty">暂时没有评论。</p>}{data && <Pagination page={page} hasMore={data.hasMore && Boolean(data.nextCursor)} onChange={change} />}</div>}
  </section>;
}

function CommentItem({ comment, reply = false }: { comment: Comment; reply?: boolean }) {
  return <article className={`comment${reply ? ' comment-reply' : ''}`}><Link to={`/creator/${comment.user.mid}`} className="comment-avatar"><img src={comment.user.avatar} alt="" loading="lazy" referrerPolicy="no-referrer" /></Link><div className="comment-body"><Link className="comment-name" to={`/creator/${comment.user.mid}`}>{comment.user.name}</Link><p>{comment.text}</p><div className="comment-meta"><span>{dateLabel(comment.createdAt)}</span>{comment.likes > 0 && <span>{countLabel(comment.likes)} 赞</span>}</div>{!reply && comment.replies?.map(item => <CommentItem key={item.id} comment={item} reply />)}</div></article>;
}

function OpenLink() {
  const wildcard = useParams()['*'] ?? ''; const location = useLocation(); const navigate = useNavigate();
  const [error, setError] = useState('');
  useEffect(() => {
    const controller = new AbortController(); setError('');
    const input = `https://www.bilibili.com/${wildcard}${location.search}${location.hash}`;
    api<{ path: string }>(`/api/resolve?input=${encodeURIComponent(input)}`, { signal: controller.signal }).then(({ path }) => {
      if (!controller.signal.aborted && /^\/(?:search(?:\?|$)|video\/|creator\/|following(?:\?|$)|$)/.test(path)) navigate(path, { replace: true });
      else if (!controller.signal.aborted) setError('这个链接暂时无法在 Bilight 中打开。');
    }).catch(error => { if (!isAbort(error)) setError(errorMessage(error)); });
    return () => controller.abort();
  }, [wildcard, location.search, location.hash, navigate]);
  return <div className="page-container">{error ? <Empty title="这个链接暂时无法打开" action={<Link to="/" className="button button-primary">返回搜索</Link>}>{error}</Empty> : <Loading text="正在打开你选择的内容" />}</div>;
}

function positivePage(value: string | null): number { const number = Number(value); return Number.isSafeInteger(number) && number > 0 && number <= 10000 ? number : 1; }
