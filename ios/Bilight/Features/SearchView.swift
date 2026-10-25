import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    var windowCenter: CGPoint
    @State private var text = ""
    @State private var submitted = ""
    @State private var users = false
    @State private var page = 1
    @State private var result: SearchResult?
    @State private var busy = false
    @State private var error: String?
    @State private var refresh = 0
    @FocusState private var focused: Bool
    @State private var introHeight: CGFloat = 80
    @State private var barHeight: CGFloat = 44
    var body: some View {
        VStack(spacing: 0) {
            if submitted.isEmpty {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .global)
                    let height = max(geometry.size.height, introHeight + 28 + barHeight + 48)
                    let minimumY = introHeight + 28 + barHeight / 2 + 24
                    let centerY = min(max(windowCenter.y - frame.minY, minimumY), height - barHeight / 2 - 24)
                    let centerX = windowCenter.x - frame.minX
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            Color.clear.contentShape(Rectangle()).onTapGesture { focused = false }
                            searchBar.frame(width: min(560, max(0, geometry.size.width - 48)))
                                .background {
                                    GeometryReader { bar in
                                        Color.clear.onAppear {
                                            barHeight = bar.size.height
                                            trace(bar.frame(in: .global))
                                        }
                                        .onChange(of: bar.frame(in: .global)) { _, value in
                                            barHeight = value.height
                                            trace(value)
                                        }
                                    }
                                }
                                .overlay(alignment: .top) {
                                    VStack(spacing: 12) {
                                        Text("想看什么？").font(.system(size: 33, weight: .bold))
                                        Text("搜你所想，看你所选").font(.system(size: 15))
                                            .foregroundStyle(Color.biliMuted).lineLimit(1).minimumScaleFactor(0.85)
                                    }.fixedSize(horizontal: false, vertical: true)
                                        .background {
                                            GeometryReader { intro in
                                                Color.clear.onAppear { introHeight = intro.size.height }
                                                    .onChange(of: intro.size.height) { _, value in introHeight = value }
                                            }
                                        }
                                        .alignmentGuide(.top) { $0[.bottom] + 28 }
                                }
                                // The field itself anchors to the window midpoint; title and footer do not affect it.
                                .position(x: centerX, y: centerY)
                        }.frame(width: geometry.size.width, height: height)
                    }.scrollBounceBehavior(.basedOnSize).scrollDismissesKeyboard(.interactively)
                        .overlay(alignment: .bottom) {
                            if !focused {
                                Text("搜索与关注，由你选择。").font(.caption).foregroundStyle(Color.biliMuted.opacity(0.8))
                                    .padding(.bottom, 35).allowsHitTesting(false)
                            }
                        }
                }
            } else {
                searchBar.padding(.horizontal, 16).padding(.vertical, 12)
                ContentTabs(
                    titles: ["视频", "UP 主"], selection: Binding(get: { users ? 1 : 0 }, set: { users = $0 == 1 })
                ).padding(.horizontal, 16).padding(.bottom, 14).onChange(of: users) { _, _ in page = 1 }
                ScrollView {
                    VStack(spacing: 0) {
                        if busy {
                            LoadingBlock(label: "正在搜索")
                        } else if let error {
                            FailureBlock(error: error) { refresh += 1 }
                        } else if let result {
                            if users {
                                if result.users.isEmpty {
                                    EmptyBlock(title: "没有找到相关 UP 主", message: "换个关键词再试试。")
                                } else {
                                    LazyVStack(spacing: 0) { ForEach(result.users) { UserRow(user: $0) } }
                                }
                            } else if result.videos.isEmpty {
                                EmptyBlock(title: "没有找到相关视频", message: "换个关键词再试试。")
                            } else {
                                VideoGrid(videos: result.videos)
                            }
                            PageButtons(page: page, more: result.hasMore, busy: busy) { page = $0 }
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 20)
                }.scrollDismissesKeyboard(.interactively)
            }
        }.task(id: "\(submitted)-\(users)-\(page)-\(refresh)") {
            guard !submitted.isEmpty else { return }
            busy = true
            error = nil
            result = nil
            do {
                let value = try await app.client.search(submitted, users: users, page: page)
                try Task.checkCancellation()
                result = value
                for user in value.users { app.register(user) }
            } catch is CancellationError { return } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
                app.handle(error)
            }
            if !Task.isCancelled { busy = false }
        }
    }
    private func trace(_ frame: CGRect) {
        guard !focused else { return }
        NativeTrace.mark(
            .searchPosition,
            [
                "x100": Int((frame.midX * 100).rounded()),
                "y100": Int((frame.midY * 100).rounded()), "targetX100": Int((windowCenter.x * 100).rounded()),
                "targetY100": Int((windowCenter.y * 100).rounded()),
            ])
    }
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.biliMuted)
            TextField("搜索视频、UP 主或 BV 号", text: $text).font(.system(size: 14)).submitLabel(.search).focused($focused)
                .onSubmit(search).autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityIdentifier("search-field")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.biliMuted.opacity(0.6))
                }.accessibilityLabel("清空搜索")
            }
            Button("搜索", action: search).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.biliPink)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(12).background(Color.biliSoft, in: RoundedRectangle(cornerRadius: 11))
    }
    private func search() {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        focused = false
        if let match = term.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression),
            term == String(term[match])
                || (URL(string: term)?.host.map { $0 == "bilibili.com" || $0.hasSuffix(".bilibili.com") } ?? false)
        {
            app.path.append(.video(String(term[match]), 1, 0))
            return
        }
        submitted = term
        page = 1
        refresh += 1
    }
}
