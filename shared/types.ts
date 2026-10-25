export interface User { mid: number; name: string; avatar: string }
export interface VideoSummary { bvid: string; aid: number; title: string; cover: string; duration: number; publishedAt: number; owner: User; views?: number }
export interface CreatorSummary extends User { description: string; fans?: number }
export interface HistoryItem extends VideoSummary { cid: number; page: number; part: string; viewedAt: number; progress: number }
export interface WatchProgress { bvid: string; cid: number; progress: number; accountMid: number; completed?: boolean }
export type CollectionKind = 'season' | 'series';
export interface CreatorCollection { id: number; mid: number; kind: CollectionKind; title: string; description: string; cover: string; count: number; updatedAt: number }
export interface CollectionPage extends Page<VideoSummary> { collection: CreatorCollection }
export interface Page<T> { items: T[]; hasMore: boolean; nextPage?: number; nextCursor?: string }
export interface SearchPage { videos: VideoSummary[]; users: CreatorSummary[]; page: number; hasMore: boolean }
export interface VideoPart { cid: number; page: number; title: string; duration: number }
export interface VideoInteraction { coinLimit: 1 | 2; likes: number; coins: number; favorites: number }
export interface VideoDetail { bvid: string; aid: number; title: string; description: string; cover: string; owner: User; parts: VideoPart[]; publishedAt: number; views: number; interaction?: VideoInteraction }
export interface Quality { id: number; label: string }
export interface Subtitle { id: string; lang: string; label: string; url: string }
export interface Playback { cid: number; quality: number; qualities: Quality[]; manifestUrl?: string; mp4Url?: string; subtitles: Subtitle[] }
export interface Danmaku { text: string; time: number; mode: number; color: string; fontSize: number }
export interface Comment { id: string; user: User; text: string; createdAt: number; likes: number; replies: Comment[] }
export interface VideoEngagement { liked: boolean; coins: number; favorited: boolean }
export interface TripleResult { state: VideoEngagement; complete: boolean }
export interface FavoriteFolder { id: number; title: string; count: number; selected: boolean; isPrivate?: boolean; isDefault?: boolean; capacity?: number }
export interface CoinInfo { state: VideoEngagement; coinLimit: 1 | 2 }
export type EngagementAction = { type: 'like'; liked: boolean } | { type: 'coin'; coins: 1 | 2; selectLike?: boolean } | { type: 'favorite'; folderIds: number[] };
export interface AuthState { authenticated: boolean; user?: User; needsLogin?: boolean; message?: string }
export interface QrChallenge { id: string; url: string; expiresAt: number }
export interface QrState { state: 'waiting' | 'scanned' | 'expired' | 'authenticated' | 'verification_required'; verificationUrl?: string }
export interface Country { id: number; name: string; code: string }
export interface CaptchaChallenge { id: string; gt: string; challenge: string }
export interface SmsSend { challengeId: string; tel: string; cid: number; challenge: string; validate: string; seccode: string }
export interface SmsTicket { id: string; expiresAt: number }
export interface LoginResult { state: 'authenticated' | 'verification_required'; verificationUrl?: string }
export interface ApiErrorBody { error: { code: string; message: string; retryable?: boolean } }
