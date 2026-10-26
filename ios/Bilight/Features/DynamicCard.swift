import SwiftUI

struct DynamicCard: View {
    @EnvironmentObject private var app: AppModel
    var post: DynamicPost
    var detail = false
    var quoted = false
    @State private var expanded = false
    @State private var gallery: PostGallerySelection?
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Button {
                    app.open(post.author)
                } label: {
                    RemoteImage(url: post.author.avatar, avatar: true).frame(
                        width: quoted ? 32 : 43, height: quoted ? 32 : 43
                    )
                    .clipShape(Circle())
                }.accessibilityLabel(post.author.name + "的主页")
                VStack(alignment: .leading, spacing: 5) {
                    Button(post.author.name) { app.open(post.author) }.font(
                        .system(size: quoted ? 14 : 15, weight: .semibold)
                    )
                    .foregroundStyle(quoted ? Color.biliBlue : .primary)
                    HStack(spacing: 5) {
                        if post.publishedAt > 0 {
                            Text(
                                Date(timeIntervalSince1970: post.publishedAt),
                                format: .dateTime.month().day().hour().minute())
                        }
                        if !post.action.isEmpty { Text(post.action) }
                    }.font(.system(size: 11)).foregroundStyle(Color.biliMuted)
                }
                Spacer(minLength: 0)
                if !quoted {
                    Menu {
                        if !detail { Button("查看动态", systemImage: "text.bubble") { app.open(post) } }
                        ShareLink(item: post.url) { Label("分享链接", systemImage: "square.and.arrow.up") }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(Color.biliMuted).frame(width: 44, height: 44)
                    }.accessibilityLabel("动态操作")
                }
            }
            if !post.title.isEmpty { Text(post.title).font(.headline).textSelection(.enabled) }
            if !post.text.isEmpty {
                Text(post.text).font(.system(size: 15)).lineSpacing(5).lineLimit(detail || expanded ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    .accessibilityIdentifier("dynamic-body-\(post.id)")
                if !detail && (post.text.count > 120 || post.text.filter({ $0 == "\n" }).count > 4) {
                    Button { expanded.toggle() } label: {
                        Text(expanded ? "收起" : "展开").font(.system(size: 14))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }.tint(Color.biliBlue)
                }
            }
            content
            if !post.warning.isEmpty {
                Label(post.warning, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            if !quoted {
                HStack {
                    ShareLink(item: post.url) {
                        Label(
                            post.forwards > 0 ? "\(countLabel(post.forwards)) 转发" : "分享",
                            systemImage: "arrowshape.turn.up.right")
                    }.accessibilityLabel("分享动态链接")
                    Spacer()
                    if !detail, post.commentID != nil, post.commentType > 0 {
                        Button {
                            app.open(post)
                        } label: {
                            Label(post.comments > 0 ? countLabel(post.comments) : "评论", systemImage: "text.bubble")
                        }.accessibilityLabel("查看评论，共\(post.comments)条")
                    } else {
                        Label(post.comments > 0 ? countLabel(post.comments) : "评论", systemImage: "text.bubble")
                    }
                    Spacer()
                    Label(
                        post.likes > 0 ? countLabel(post.likes) : "赞",
                        systemImage: post.liked ? "hand.thumbsup.fill" : "hand.thumbsup"
                    )
                    .foregroundStyle(post.liked ? Color.biliPink : Color.biliMuted)
                    .accessibilityLabel("\(post.likes)赞" + (post.liked ? "，已点赞" : ""))
                }.font(.system(size: 13)).foregroundStyle(Color.biliMuted).padding(.top, 6).frame(minHeight: 36)
            }
        }.buttonStyle(.plain).fullScreenCover(item: $gallery) { selection in
            PostGallery(images: selection.images, selection: selection.index)
        }
    }
    @ViewBuilder private var content: some View {
        switch post.content {
        case .text: EmptyView()
        case .video(let video):
            Button {
                app.open(video)
            } label: {
                VStack(alignment: .leading, spacing: 9) {
                    RemoteImage(url: video.cover).aspectRatio(16 / 9, contentMode: .fit)
                        .overlay(alignment: .bottom) {
                            HStack {
                                Label(countLabel(video.views), systemImage: "play.rectangle")
                                Spacer()
                                Text(timeLabel(video.duration)).monospacedDigit()
                            }.font(.system(size: 11)).foregroundStyle(.white).padding(9)
                                .background(
                                    LinearGradient(
                                        colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                        }.clipShape(RoundedRectangle(cornerRadius: 7))
                    Text(video.title).font(.system(size: 15, weight: .medium)).lineLimit(2).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
            }.accessibilityLabel("播放视频：" + video.title)
        case .pictures(let images):
            if let image = images.first, images.count == 1 {
                Button {
                    gallery = PostGallerySelection(images: images, index: 0)
                } label: {
                    RemoteImage(url: image.url).aspectRatio(min(1.8, max(0.8, image.aspect)), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }.accessibilityLabel("查看图片")
            } else if !images.isEmpty {
                let columns = images.count == 2 || images.count == 4 ? 2 : 3
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                    ForEach(Array(images.prefix(9).enumerated()), id: \.element.id) { index, image in
                        Button {
                            gallery = PostGallerySelection(images: images, index: index)
                        } label: {
                            RemoteImage(url: image.url).aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 5)).overlay {
                                    if index == 8, images.count > 9 {
                                        RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.45))
                                        Text("+\(images.count - 9)").font(.title2.bold()).foregroundStyle(.white)
                                    }
                                }
                        }.accessibilityLabel("查看第\(index + 1)张图片，共\(images.count)张")
                    }
                }
            }
        case .repost(let original):
            AnyView(DynamicCard(post: original, detail: detail, quoted: true))
                .padding(12).background(Color.biliSoft, in: RoundedRectangle(cornerRadius: 7))
            if !detail { Button("查看原动态") { app.open(original) }.font(.caption).tint(Color.biliBlue) }
        case .link(let link):
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    if let cover = link.cover {
                        RemoteImage(url: cover).frame(width: 76, height: 76).clipShape(
                            RoundedRectangle(cornerRadius: 5))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(link.title).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                        Text(link.summary).font(.system(size: 12)).foregroundStyle(Color.biliMuted).lineLimit(
                            detail ? nil : 3)
                        Text(link.label).font(.system(size: 10)).foregroundStyle(Color.biliBlue)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if detail, let url = link.url {
                    Link("打开原文", destination: url).font(.footnote).tint(Color.biliBlue)
                } else if !detail {
                    Button("查看动态") { app.open(post) }.font(.footnote).tint(Color.biliBlue)
                }
            }.padding(10).background(Color.biliSoft, in: RoundedRectangle(cornerRadius: 6))
        case .unavailable(let reason):
            Text(reason).font(.footnote).foregroundStyle(Color.biliMuted).frame(
                maxWidth: .infinity, alignment: .leading
            )
            .padding(14).background(Color.biliSoft, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
private struct PostGallerySelection: Identifiable {
    let id = UUID()
    var images: [PostImage]
    var index: Int
}
private struct PostGallery: View {
    @Environment(\.dismiss) private var dismiss
    var images: [PostImage]
    @State var selection: Int
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    // Only the selected image and its neighbours are requested, even in a long gallery.
                    Group {
                        if abs(index - selection) <= 1 { PostGalleryImage(image: image) } else { Color.black }
                    }.tag(index)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            HStack {
                Text("\(selection + 1) / \(images.count)").font(.subheadline.monospacedDigit())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("关闭图片")
            }.foregroundStyle(.white).padding(.horizontal, 20)
        }.preferredColorScheme(.dark)
    }
}
private struct PostGalleryImage: View {
    var image: PostImage
    @State private var value: UIImage?
    @State private var error = false
    @State private var retry = 0
    var body: some View {
        ZStack {
            Color.black
            if let value {
                Image(uiImage: value).resizable().scaledToFit()
            } else if error {
                Button("重新加载图片") { retry += 1 }.tint(.white)
            } else {
                ProgressView().tint(.white)
            }
        }.task(id: retry) {
            error = false
            do { value = try await ImageRepository.shared.image(image.url) } catch is CancellationError { return } catch
            { if !Task.isCancelled { self.error = true } }
        }
    }
}
