import { readFileSync } from 'node:fs';

// Public creator/video snapshots selected by the user; account state and history are fictional.
const content = JSON.parse(readFileSync(new URL('./demo-public-content.json', import.meta.url), 'utf8'));
export const stamp = 1792922400;
export const people = content.creators;
export const account = { mid: 910000, name: 'Bilight 演示', avatar: '/demo-assets/demo-avatar-0.png' };
export const videos = content.videos.map(video => ({ ...video, owner: people.find(person => person.mid === video.ownerMid), views: video.statistics.view }));
export const collections = content.collections;
export const history = videos.slice(0, 4).map((video, i) => ({ video, cid: video.parts[0].cid, page: 1, part: video.parts[0].part, progress: Math.min(video.duration, [41, 123, 65, 218][i]), viewedAt: stamp - i * 3600, completed: false }));
export const page = items => ({ items, hasMore: false });
const imageURL = path => `https://i0.hdslb.com/bilight-demo/${path.split('/').at(-1)}`;
const rawUser = user => ({ mid: user.mid, name: user.name, uname: user.name, face: imageURL(user.avatar), sign: user.description ?? '', fans: user.fans ?? 0, attribute: 2, mtime: stamp });
const rawVideo = video => ({ ...video, pic: imageURL(video.cover), pubdate: video.publishedAt, owner: rawUser(video.owner), stat: video.statistics });
const detail = video => ({ ...rawVideo(video), cid: video.parts[0].cid, desc: '', pages: video.parts });
const directory = mid => {
  const items = collections.filter(group => group.mid === mid);
  return { items_lists: { page: { page_size: 12, total: items.length }, seasons_list: items.filter(x => x.kind === 'season').map(x => ({ meta: { season_id: x.id, mid: x.mid, name: x.title, description: x.description, cover: imageURL(x.cover), total: x.count } })), series_list: [] } };
};
const dynamic = (video, i) => ({ id_str: `95000${i + 1}`, type: 'DYNAMIC_TYPE_AV', basic: { comment_id_str: `95000${i + 1}`, comment_type: 17 }, modules: { module_author: { ...rawUser(video.owner), pub_ts: video.publishedAt, pub_action: '投稿了视频' }, module_dynamic: { major: { type: 'MAJOR_TYPE_ARCHIVE', archive: rawVideo(video) } }, module_stat: { like: { count: video.statistics.like, status: false }, comment: { count: video.statistics.reply }, forward: { count: 0 } } } });
export const nativeFixtures = {
  '/x/web-interface/wbi/view': detail(videos[0]),
  '/x/web-interface/archive/relation': { like: false, coin: 0, favorite: false },
  '/x/v3/fav/folder/created/list-all': { count: 2, list: [{ id: 960001, mid: 910000, title: '默认收藏夹', media_count: 12, fav_state: 0, attr: 0 }, { id: 960002, mid: 910000, title: '慢慢看', media_count: 8, fav_state: 0, attr: 3 }] },
  '/x/web-interface/nav': { ...rawUser(account), isLogin: true, wbi_img: { img_url: 'https://i0.hdslb.com/bfs/wbi/0123456789abcdef0123456789abcdef.png', sub_url: 'https://i0.hdslb.com/bfs/wbi/fedcba9876543210fedcba9876543210.png' } },
  '/x/relation/followings': { list: people.map(rawUser), total: people.length },
  '/x/relation/relations': Object.fromEntries(people.map(user => [user.mid, { mid: user.mid, attribute: 2 }])),
  '/x/relation': { attribute: 2 },
  '/x/frontend/finger/spi': { b_3: 'BILIGHT_DEMO_ONLY_OFFLINE', b_4: 'BILIGHT_DEMO_ONLY_OFFLINE' },
  '/x/polymer/web-dynamic/v1/feed/all': { has_more: 0, offset: '', items: videos.map(dynamic) },
  '/x/web-interface/wbi/search/type': { result: videos.map(rawVideo), numPages: 1, numResults: videos.length },
  '/x/space/wbi/acc/info': rawUser(people[0]),
  '/x/space/wbi/arc/search': { list: { vlist: videos.filter(x => x.owner.mid === people[0].mid).map(rawVideo) }, page: { count: videos.filter(x => x.owner.mid === people[0].mid).length } },
  '/x/polymer/web-space/seasons_series_list': directory(people[0].mid),
  '/x/web-interface/history/cursor': { list: history.map(record => ({ title: record.video.title, cover: imageURL(record.video.cover), author_mid: record.video.owner.mid, author_name: record.video.owner.name, author_face: imageURL(record.video.owner.avatar), duration: record.video.duration, progress: record.progress, view_at: record.viewedAt, history: { business: 'archive', bvid: record.video.bvid, oid: record.video.aid, cid: record.cid, page: 1, part: record.part } })), cursor: { max: 0, view_at: 0, business: '' } },
  _preview: { creators: Object.fromEntries(people.map(user => [user.mid, rawUser(user)])), videos: Object.fromEntries(videos.map(video => [video.bvid, detail(video)])), directories: Object.fromEntries(people.map(user => [user.mid, directory(user.mid)])) },
};
nativeFixtures['/x/web-interface/view'] = nativeFixtures['/x/web-interface/wbi/view'];
