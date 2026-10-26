#if DEBUG
import SwiftUI

/// Explicit, offline UI regression fixture. It never restores the user's account.
enum InteractionRegression {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--interaction-regression") || player }
    static var player: Bool { ProcessInfo.processInfo.arguments.contains("--regression-player") }
    static var grid: Bool { ProcessInfo.processInfo.arguments.contains("--regression-grid") }
    static let imageURL = URL(string: "https://i0.hdslb.com/bilight-regression/tall.png")!
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

struct InteractionRegressionView: View {
    @State private var ready = false
    private var post: DynamicPost {
        let images = (0..<(InteractionRegression.grid ? 4 : 1)).map { index in
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
