#if DEBUG
import SwiftUI

/// Explicit, offline UI regression fixture. It never restores the user's account.
enum InteractionRegression {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--interaction-regression") || player || commentComposer }
    static var player: Bool { ProcessInfo.processInfo.arguments.contains("--regression-player") }
    static var commentComposer: Bool { ProcessInfo.processInfo.arguments.contains("--regression-video-comment") || dynamicComments }
    static var dynamicComments: Bool { ProcessInfo.processInfo.arguments.contains("--regression-dynamic-comments") }
    static let dynamicID = "1057955152016703512"
    static let dynamicCommentOID = "1057955152016703513"
    static var gallery: Bool { ProcessInfo.processInfo.arguments.contains("--regression-gallery") }
    static var grid: Bool { ProcessInfo.processInfo.arguments.contains("--regression-grid") }
    static let imageURL = URL(string: "https://i0.hdslb.com/bilight-regression/tall.png")!
    @MainActor static func galleryImage(_ url: URL) -> UIImage {
        if dynamicComments {
            return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
                UIColor(red: 0.08, green: 0.94, blue: 0.19, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            }
        }
        guard gallery else { return image }
        let index = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "index" }?.value ?? "0") ?? 0
        let size = index < 4 ? CGSize(width: 800, height: 800) : (index.isMultiple(of: 2) ? CGSize(width: 800, height: 300) : CGSize(width: 200, height: 800))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            (index.isMultiple(of: 2) ? UIColor.systemPink : UIColor.systemBlue).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("图片 \(index + 1)" as NSString).draw(at: CGPoint(x: 20, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 50), .foregroundColor: UIColor.white])
        }
    }
    @MainActor static let image: UIImage = {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 80, height: 800), format: format).image { context in
            for index in 0..<10 {
                (index.isMultiple(of: 2) ? UIColor.systemPink : UIColor.systemBlue).setFill()
                context.fill(CGRect(x: 0, y: index * 80, width: 80, height: 80))
            }
        }
    }()
}

struct VideoCommentComposerRegressionView: View {
    @EnvironmentObject private var app: AppModel
    @State private var ready = false
    @State private var aid = 42
    var body: some View {
        if ready {
            if InteractionRegression.dynamicComments {
                NavigationStack {
                    DynamicDetailView(id: InteractionRegression.dynamicID)
                }
            } else {
                VStack {
                    Button("切换测试视频") { aid = aid == 42 ? 43 : 42 }
                    ScrollView {
                        VStack(spacing: 18) {
                            VideoDescriptionSection(description: "测试视频 \(aid) 简介")
                            CommentsView(oid: "\(aid)", channel: .video(aid: aid, bvid: "BV0000000001"), remembersExpansion: true)
                        }.id(aid).padding(12)
                    }.frame(width: 320)
                }
            }
        } else {
            ProgressView().task {
                try? await app.client.http.restore()
                app.user = User(mid: 3, name: "隔离测试账号", avatar: nil)
                ready = true
            }
        }
    }
}

struct InteractionRegressionView: View {
    @State private var ready = false
    private var post: DynamicPost {
        let images = (0..<(InteractionRegression.gallery ? 8 : InteractionRegression.grid ? 4 : 1)).map { index in
            PostImage(url: URL(string: InteractionRegression.imageURL.absoluteString + "?index=\(index)")!, width: 80, height: 800)
        }
        return DynamicPost(id: "123456789", author: User(mid: 7, name: "测试作者", avatar: nil), publishedAt: 0,
            action: "发布了图文", text: String(repeating: "这是用于验证图文展开的正文，点击展开应显示完整内容。\n", count: 9) + "正文末尾标记",
            title: "图文点击回归", content: .pictures(images),
            comments: 0, forwards: 0, likes: 0, liked: false, commentType: 0, warning: "")
    }
    var body: some View {
        ScrollView {
            if ready {
                DynamicCard(post: post).padding(16)
                Text("图片已准备").accessibilityIdentifier("regression-ready")
            }
        }.task {
            _ = try? await ImageRepository.shared.image(InteractionRegression.imageURL)
            ready = true
        }
    }
}
#endif
