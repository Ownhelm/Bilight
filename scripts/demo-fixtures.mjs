// Entirely fictional publication fixtures. Never derived from a signed-in account.
export const stamp = 1792922400;
export const asset = name => `/demo-assets/demo-${name}.png`;
export const people = [
  { mid: 910001, name: '山间放映室', avatar: asset('avatar-1'), description: '把沿途的风景，慢慢记录下来。', fans: 12800 },
  { mid: 910002, name: '像素笔记', avatar: asset('avatar-2'), description: '写点代码，也记录创造的过程。', fans: 8600 },
  { mid: 910003, name: '慢慢观察', avatar: asset('avatar-3'), description: '一些日常，一些不着急的发现。', fans: 5600 },
];
export const account = { mid: 910000, name: 'Bilight 演示', avatar: asset('avatar-0') };
const titles = ['去山里，等一场日落', '从零做一个小工具', '给周末留一点空白', '一扇窗，一整个下午', '把想法变成看得见的东西', '沿着海岸慢慢走', '收集城市里的蓝色', '简单一点，也挺好'];
const covers = ['mountain', 'code', 'waves', 'window', 'code', 'waves', 'window', 'mountain'];
export const videos = titles.map((title, i) => ({ bvid: `BV${String(i + 1).padStart(10, '0')}`, aid: 920001 + i, title, cover: asset(covers[i]), duration: [260, 728, 365, 482, 930, 604, 351, 270][i], publishedAt: stamp - i * 3600, owner: people[i % 3], views: 12600 - i * 930 }));
export const collections = [
  { id: 930001, mid: people[0].mid, kind: 'season', title: '山野之间', description: '走进山里，也回到生活里。', cover: asset('mountain'), count: 12 },
  { id: 930002, mid: people[0].mid, kind: 'season', title: '海边来信', description: '关于海风、浪花和漫长的下午。', cover: asset('waves'), count: 8 },
  { id: 930003, mid: people[0].mid, kind: 'series', title: '慢旅行日记', description: '沿途记录，按出发的顺序。', cover: asset('window'), count: 16 },
];
export const history = videos.slice(0, 4).map((video, i) => ({ video, cid: 940001 + i, page: 1, part: video.title, progress: [41, 123, 65, 218][i], viewedAt: stamp - i * 3600, completed: false }));
export const page = items => ({ items, hasMore: false });
const imageURL = path => `https://i0.hdslb.com/bilight-demo/${path.split('/').at(-1)}`;
const rawUser = user => ({ mid: user.mid, name: user.name, uname: user.name, face: imageURL(user.avatar), sign: user.description ?? '', fans: user.fans ?? 0, attribute: 2, mtime: stamp });
const rawVideo = video => ({ ...video, pic: imageURL(video.cover), pubdate: video.publishedAt, owner: rawUser(video.owner), stat: { view: video.views } });
const dynamic = (i, content) => ({ id_str: `95000${i + 1}`, type: i === 1 ? 'DYNAMIC_TYPE_WORD' : 'DYNAMIC_TYPE_AV', basic: { comment_id_str: `95000${i + 1}`, comment_type: 17 }, modules: { module_author: { ...rawUser(people[i % 3]), pub_ts: stamp - i * 3600, pub_action: i === 1 ? '发布了动态' : '投稿了视频' }, module_dynamic: content, module_stat: { like: { count: 128 - i * 15, status: false }, comment: { count: 12 + i }, forward: { count: 6 + i } } } });
export const nativeFixtures = {
  '/x/web-interface/nav': { ...rawUser(account), isLogin: true, wbi_img: { img_url: 'https://i0.hdslb.com/bfs/wbi/0123456789abcdef0123456789abcdef.png', sub_url: 'https://i0.hdslb.com/bfs/wbi/fedcba9876543210fedcba9876543210.png' } },
  '/x/relation/followings': { list: people.map(rawUser), total: people.length },
  '/x/relation/relations': Object.fromEntries(people.map(user => [user.mid, { mid: user.mid, attribute: 2 }])),
  '/x/relation': { attribute: 2 },
  '/x/frontend/finger/spi': { b_3: 'BILIGHT_DEMO_ONLY_OFFLINE', b_4: 'BILIGHT_DEMO_ONLY_OFFLINE' },
  '/x/polymer/web-dynamic/v1/feed/all': { has_more: 0, offset: '', items: [
    dynamic(0, { desc: { text: '今天的风很轻，适合去山里走走。' }, major: { type: 'MAJOR_TYPE_ARCHIVE', archive: rawVideo(videos[0]) } }),
    dynamic(1, { desc: { text: '把一个小想法做出来，就是今天最开心的事。\n下次见面，分享它是怎么诞生的。' } }),
    dynamic(2, { major: { type: 'MAJOR_TYPE_ARCHIVE', archive: rawVideo(videos[2]) } }),
  ] },
  '/x/web-interface/wbi/search/type': { result: videos.map(rawVideo), numPages: 1, numResults: videos.length },
  '/x/space/wbi/acc/info': rawUser(people[0]),
  '/x/space/wbi/arc/search': { list: { vlist: videos.map(rawVideo) }, page: { count: videos.length } },
  '/x/polymer/web-space/seasons_series_list': { items_lists: { page: { page_size: 12, total: 3 }, seasons_list: collections.filter(x => x.kind === 'season').map(x => ({ meta: { season_id: x.id, mid: x.mid, name: x.title, description: x.description, cover: imageURL(x.cover), total: x.count } })), series_list: collections.filter(x => x.kind === 'series').map(x => ({ meta: { series_id: x.id, mid: x.mid, name: x.title, description: x.description, cover: imageURL(x.cover), total: x.count } })) } },
  '/x/web-interface/history/cursor': { list: videos.slice(0, 4).map((video, i) => ({ title: video.title, cover: imageURL(video.cover), author_mid: video.owner.mid, author_name: video.owner.name, author_face: imageURL(video.owner.avatar), duration: video.duration, progress: history[i].progress, view_at: stamp - i * 3600, history: { business: 'archive', bvid: video.bvid, oid: video.aid, cid: history[i].cid, page: 1, part: video.title } })), cursor: { max: 0, view_at: 0, business: '' } },
};
