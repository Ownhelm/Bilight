import SwiftUI

struct DynamicDetailView: View {
    @EnvironmentObject private var app: AppModel
    var id: String
    @State private var post: DynamicPost?
    @State private var busy = true
    @State private var error: String?
    @State private var refresh = 0
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if let post {
                    DynamicCard(post: post, detail: true)
                    if let oid = post.commentID, post.commentType > 0 {
                        Divider()
                        CommentsView(oid: oid, commentType: post.commentType).id("\(oid)-\(post.commentType)")
                    }
                }
                if busy { LoadingBlock(label: "正在读取动态") }
                if let error { FailureBlock(error: error) { refresh += 1 } }
            }.padding(16)
        }.navigationTitle("动态详情").navigationBarTitleDisplayMode(.inline).task(id: "\(id)-\(refresh)") {
            let generation = app.accountGeneration
            if post == nil { post = app.dynamics[id] }
            busy = true
            error = nil
            defer { busy = false }
            do {
                let result = try await app.client.dynamic(id)
                try Task.checkCancellation()
                guard app.accountGeneration == generation else { return }
                post = result
                app.dynamics[id] = result
            } catch is CancellationError { return } catch {
                guard !Task.isCancelled, app.accountGeneration == generation else { return }
                self.error = error.localizedDescription
                app.handle(error)
            }
        }
    }
}
