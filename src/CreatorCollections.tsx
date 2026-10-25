import { Link } from 'react-router-dom';
import { ArrowLeft, Stack } from '@phosphor-icons/react';
import type { CollectionKind, CollectionPage, CreatorCollection, CreatorSummary, Page } from '../shared/types';
import { Empty, Failure, Loading, Pagination, useResource, VideoGrid } from './components';

export function CreatorCollections({ mid, page, refresh, onRetry, onPage }: { mid: string; page: number; refresh: number; onRetry: () => void; onPage: (page: number) => void }) {
  const { data, error, loading } = useResource<Page<CreatorCollection>>(`/api/creators/${encodeURIComponent(mid)}/collections?page=${page}`, refresh);
  return <>{loading ? <Loading text="正在读取合集和视频列表" /> : error ? <Failure error={error} retry={onRetry} /> : data?.items.length ? <>
    {(['season', 'series'] as const).map(kind => { const items = data.items.filter(item => item.kind === kind); return items.length ? <section className="collection-group" key={kind}><div className="list-heading"><h2>{kind === 'season' ? '合集' : '视频列表'}</h2><span>{items.length} 个</span></div><div className="collection-grid">{items.map(item => <Link className="collection-card" key={`${kind}:${item.id}`} to={`/creator/${mid}/collections/${kind}/${item.id}`}><div className="collection-cover">{item.cover && <img src={item.cover} alt="" loading="lazy" />}<span className="collection-count"><Stack size={14} />{item.count} 个视频</span></div><h3>{item.title}</h3><p>{item.description || (kind === 'season' ? '查看合集视频' : '查看列表视频')}</p></Link>)}</div></section> : null; })}
  </> : <Empty title={data?.hasMore ? '本页没有合集或列表' : '这位 UP 主暂时没有公开的合集或视频列表'}>{data?.hasMore ? '可以继续翻页查看。' : '公开分组会在这里显示。'}</Empty>}
    {data && <Pagination page={page} hasMore={data.hasMore} onChange={onPage} />}
  </>;
}

export function CreatorCollectionVideos({ mid, kind, id, page, profile, refresh, onRetry, onPage }: { mid: string; kind: CollectionKind; id: string; page: number; profile: CreatorSummary | null; refresh: number; onRetry: () => void; onPage: (page: number) => void }) {
  const { data, error, loading } = useResource<CollectionPage>(`/api/creators/${encodeURIComponent(mid)}/collections/${kind}/${encodeURIComponent(id)}?page=${page}`, refresh);
  const videos = data?.items.map(video => profile && !video.owner.name ? { ...video, owner: profile } : video);
  return <section className="collection-detail"><Link className="back-link" to={`/creator/${mid}?tab=collections`}><ArrowLeft size={15} />返回合集和列表</Link>
    {loading ? <Loading text="正在读取列表视频" /> : error ? <Failure error={error} retry={onRetry} /> : data && <><div className="collection-title"><span className="collection-kind">{kind === 'season' ? '合集' : '视频列表'}</span><h2>{data.collection.title}</h2><span>{data.collection.count} 个视频</span></div>{data.collection.description && <p className="collection-description">{data.collection.description}</p>}<p className="collection-order">按列表顺序展示，手动选择播放。</p>{videos?.length ? <VideoGrid videos={videos} /> : <Empty title="这个分组暂时没有可播放的视频" />}<Pagination page={page} hasMore={data.hasMore} onChange={onPage} /></>}
  </section>;
}
