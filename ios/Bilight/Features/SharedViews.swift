import ImageIO
import SwiftUI

actor ImageRepository {
    static let shared = ImageRepository()
    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = URLCache(memoryCapacity: 24 * 1024 * 1024, diskCapacity: 0)
        session = URLSession(configuration: config)
        cache.totalCostLimit = 48 * 1024 * 1024
    }
    func image(_ url: URL) async throws -> UIImage {
        #if DEBUG
            if DemoFixtures.enabled {
                guard let image = DemoFixtures.image(url) else { throw BiliFailure.invalid }
                return image
            }
        #endif
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard MediaLoader.allowed(url) || BiliHTTP.trusted(url) else { throw BiliFailure.invalid }
        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue(BiliHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.mimeType?.hasPrefix("image/") == true,
            data.count < 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 800,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
        else { throw BiliFailure.invalid }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
        return image
    }
}
struct RemoteImage: View {
    var url: URL?
    var avatar = false
    @State private var image: UIImage?
    var body: some View {
        Color.biliSoft.overlay {
            // The container sets layout size; a cover's aspect-fill image must not widen a grid cell.
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: avatar ? "person.fill" : "play.rectangle").foregroundStyle(
                    Color.biliMuted.opacity(0.35)
                ).font(.system(size: avatar ? 18 : 28, weight: .light))
            }
        }.clipped().task(id: url) {
            image = nil
            if let url { image = try? await ImageRepository.shared.image(url) }
        }.accessibilityHidden(true)
    }
}
struct LoadingBlock: View {
    var label = "正在加载"
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Color.biliPink)
            Text(label).font(.footnote).foregroundStyle(Color.biliMuted)
        }.frame(maxWidth: .infinity).padding(.vertical, 45)
    }
}
struct FailureBlock: View {
    var error: String
    var retry: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(Color.biliMuted)
            Text(error).font(.footnote).foregroundStyle(Color.biliMuted).multilineTextAlignment(.center)
            Button("重新加载", action: retry).font(.footnote.weight(.semibold)).tint(Color.biliPink)
        }.padding(30).frame(maxWidth: .infinity)
    }
}
struct EmptyBlock: View {
    var symbol = "play.rectangle"
    var title: String
    var message = ""
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 35, weight: .ultraLight)).foregroundStyle(
                Color.biliMuted.opacity(0.5))
            Text(title).font(.subheadline.weight(.medium))
            if !message.isEmpty {
                Text(message).font(.footnote).foregroundStyle(Color.biliMuted).multilineTextAlignment(.center)
            }
        }.frame(maxWidth: .infinity).padding(.horizontal, 30).padding(.vertical, 55)
    }
}
struct FollowButton: View {
    @EnvironmentObject private var app: AppModel
    var mid: Int
    var compact = false
    @State private var error: String?
    var body: some View {
        let following = app.relations[mid]?.following == true
        if app.user?.mid != mid {
            Button(action: toggle) {
                Group {
                    if app.followBusy.contains(mid) {
                        ProgressView().tint(Color.biliPink).scaleEffect(0.65)
                    } else {
                        Image(systemName: following ? (app.relations[mid]?.mutual == true ? "arrow.left.arrow.right" : "checkmark") : "plus")
                            .font(.system(size: compact ? 13 : 14, weight: .medium))
                    }
                }.frame(width: compact ? 30 : 32, height: 26)
                    .foregroundStyle(following ? Color.biliPink : Color.biliMuted.opacity(0.65))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).stroke(
                            following ? Color.biliPink.opacity(0.25) : Color.biliMuted.opacity(0.22), lineWidth: 0.7)
                    }
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(app.followBusy.contains(mid)).accessibilityLabel(
                app.relations[mid]?.following == true ? "取消关注" : "关注 UP 主"
            )
            .accessibilityValue(app.relations[mid]?.mutual == true ? "互相关注" : app.relations[mid]?.following == true ? "已关注" : "未关注")
            .task(id: "\(mid)-\(app.user?.mid ?? 0)") {
                if app.relations[mid] == nil { await app.readRelation(mid) }
            }
            .alert("关注操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }
    private func toggle() {
        Task {
            do { try await app.follow(mid, following: !(app.relations[mid]?.following ?? false)) } catch {
                self.error = error.localizedDescription
                app.handle(error)
            }
        }
    }
}
struct UserRow: View {
    @EnvironmentObject private var app: AppModel
    var user: User
    var body: some View {
        HStack(spacing: 12) {
            Button {
                app.open(user)
            } label: {
                RemoteImage(url: user.avatar, avatar: true).frame(width: 58, height: 58).clipShape(Circle())
            }
            Button {
                app.open(user)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(user.name).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    if let fans = user.fans {
                        Text("\(countLabel(fans)) 粉丝").font(.caption).foregroundStyle(Color.biliMuted)
                    }
                    if !user.description.isEmpty {
                        Text(user.description).font(.caption).foregroundStyle(Color.biliMuted).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            FollowButton(mid: user.mid, compact: true)
        }.buttonStyle(.plain).padding(.vertical, 16)
    }
}
struct VideoCard: View {
    @EnvironmentObject private var app: AppModel
    var video: Video
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                app.open(video)
            } label: {
                RemoteImage(url: video.cover).aspectRatio(16 / 10, contentMode: .fit).overlay(
                    alignment: .bottomTrailing
                ) {
                    Text(timeLabel(video.duration)).font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 3).background(
                            .black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3)
                        ).padding(5)
                }.clipShape(RoundedRectangle(cornerRadius: 7))
            }
            Button {
                app.open(video)
            } label: {
                Text(video.title).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(
                    .leading
                ).frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            }
            Button {
                app.open(video.owner)
            } label: {
                HStack(spacing: 4) {
                    Text("UP").font(.system(size: 8, weight: .medium)).padding(.horizontal, 2).overlay(
                        RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 0.6))
                    Text(video.owner.name).font(.system(size: 10)).lineLimit(1)
                    Spacer(minLength: 0)
                }.foregroundStyle(Color.biliMuted)
            }
            HStack(spacing: 7) {
                if video.views > 0 { Text("\(countLabel(video.views)) 播放") }
                if video.publishedAt > 0 { Text(Date(timeIntervalSince1970: video.publishedAt), style: .date) }
            }.font(.system(size: 9)).foregroundStyle(Color.biliMuted)
        }.buttonStyle(.plain)
    }
}
struct VideoGrid: View {
    var videos: [Video]
    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading,
            spacing: 23
        ) { ForEach(videos) { VideoCard(video: $0) } }
    }
}
struct PageButtons: View {
    var page: Int
    var more: Bool
    var busy: Bool
    var change: (Int) -> Void
    var body: some View {
        HStack(spacing: 24) {
            Button("上一页") { change(page - 1) }.disabled(page <= 1 || busy)
            Text("第 \(page) 页").foregroundStyle(Color.biliMuted)
            Button("下一页") { change(page + 1) }.disabled(!more || busy)
        }.font(.footnote).tint(Color.biliPink).frame(maxWidth: .infinity).padding(.vertical, 25)
    }
}

struct ContentTabs: View {
    var titles: [String]
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 26) {
            ForEach(titles.indices, id: \.self) { index in
                Button {
                    selection = index
                } label: {
                    Text(titles[index]).font(.system(size: 15, weight: selection == index ? .semibold : .regular))
                        .foregroundStyle(selection == index ? Color.biliPink : Color.biliMuted).padding(.vertical, 13)
                        .overlay(alignment: .bottom) {
                            if selection == index { Capsule().fill(Color.biliPink).frame(width: 23, height: 3) }
                        }
                }.buttonStyle(.plain).accessibilityAddTraits(selection == index ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.06)).frame(height: 0.5) }
            .accessibilityElement(children: .contain)
    }
}
