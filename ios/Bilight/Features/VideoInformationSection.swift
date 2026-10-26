import SwiftUI

/// Shared by the live playback page and size-matrix checks; the player remains owned by PlaybackView.
struct VideoInformationSection: View {
    @EnvironmentObject private var app: AppModel
    var detail: VideoDetail
    var part: VideoPart
    @ObservedObject var model: PlayerModel
    var onDownload: () -> Void
    @ScaledMetric(relativeTo: .body) private var ownerSize: CGFloat = 14
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 19
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button {
                        app.open(detail.video.owner)
                    } label: {
                        HStack(spacing: 10) {
                            RemoteImage(url: detail.video.owner.avatar, avatar: true).frame(width: 38, height: 38)
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(detail.video.owner.name).font(.system(size: ownerSize, weight: .medium))
                                    .foregroundStyle(.primary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                if let fans = detail.video.owner.fans {
                                    Text("\(countLabel(fans)) 粉丝").font(.caption2).foregroundStyle(Color.biliMuted).lineLimit(1).minimumScaleFactor(0.7)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 44)
                    }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                    FollowButton(mid: detail.video.owner.mid)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(detail.video.title).font(.system(size: titleSize, weight: .semibold)).fixedSize(
                        horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 13) {
                            Text("\(countLabel(detail.video.views)) 播放")
                            Text(detail.video.bvid)
                        }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(countLabel(detail.video.views)) 播放")
                            Text(detail.video.bvid).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }.font(.caption2).foregroundStyle(Color.biliMuted)
                }
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            VideoActionBar(model: model, bvid: detail.video.bvid, cid: part.cid, statistics: detail.statistics, onDownload: onDownload)
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 0.5).padding(.horizontal, 16).padding(.top, 12)
        }
    }
}
