import SwiftUI

private let titleFilterLabel = "仅标题匹配"

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
    @State private var loadedRequest: String?
    @AppStorage("search.video.order") private var order: VideoSearchOrder = .relevance
    @AppStorage("search.video.titleOnly") private var titleOnly = false
    @State private var showFilters = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var focused: Bool
    @State private var introHeight: CGFloat = 80
    @State private var barHeight: CGFloat = 44
    private var requestID: String { "\(submitted)-\(users)-\(page)-\(refresh)-\(users ? "" : order.rawValue)" }

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
                                        HStack(spacing: 8) {
                                            Image("PlaybackMark").renderingMode(.template).resizable().scaledToFit().frame(width: 36, height: 32)
                                            Text("Bilight").font(.system(size: 36, weight: .bold, design: .rounded))
                                        }.foregroundStyle(Color.biliPink)
                                            .accessibilityElement(children: .ignore).accessibilityLabel("Bilight")
                                            .accessibilityAddTraits(.isHeader)
                                        Text("搜你所想，看你所选").font(.system(size: 16))
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
                                // The field itself anchors to the window midpoint independently of the logo and caption.
                                .position(x: centerX, y: centerY)
                        }.frame(width: geometry.size.width, height: height)
                    }.scrollBounceBehavior(.basedOnSize).scrollDismissesKeyboard(.interactively)
                }
            } else {
                searchBar.padding(.horizontal, 16).padding(.vertical, 12)
                ContentTabs(
                    titles: ["视频", "UP 主"], selection: Binding(get: { users ? 1 : 0 }, set: { selection in
                        guard users != (selection == 1) else { return }
                        users = selection == 1
                        page = 1
                    })
                ).overlay(alignment: .trailing) {
                    if !users { searchFilter }
                }.padding(.horizontal, 16).padding(.bottom, 14)
                ScrollView {
                    VStack(spacing: 0) {
                        if busy {
                            LoadingBlock(label: "正在搜索")
                        } else if let error {
                            FailureBlock(error: error) { refresh += 1 }
                        } else if let result, loadedRequest == requestID {
                            let videos = titleOnly ? result.videosMatchingTitle(submitted) : result.videos
                            if users {
                                if result.users.isEmpty {
                                    EmptyBlock(title: "没有找到相关 UP 主", message: "换个关键词再试试。")
                                } else {
                                    LazyVStack(spacing: 0) { ForEach(result.users) { UserRow(user: $0) } }
                                }
                            } else if videos.isEmpty {
                                if titleOnly {
                                    EmptyBlock(
                                        title: "本页没有标题匹配的视频",
                                        message: result.hasMore ? "可以翻到下一页，或关闭「\(titleFilterLabel)」。" : "可以关闭「\(titleFilterLabel)」，或换个关键词。")
                                } else {
                                    EmptyBlock(title: "没有找到相关视频", message: "换个关键词再试试。")
                                }
                            } else {
                                VideoGrid(videos: videos)
                            }
                            PageButtons(page: page, more: result.hasMore, busy: busy) { page = $0 }
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 20)
                }.scrollDismissesKeyboard(.interactively).id("\(requestID)-\(!users && titleOnly)")
            }
        }.task(id: requestID) {
            guard !Task.isCancelled, !submitted.isEmpty, loadedRequest != requestID else { return }
            let identity = requestID
            busy = true
            error = nil
            result = nil
            do {
                let value = try await app.client.search(submitted, users: users, page: page, order: order)
                try Task.checkCancellation()
                guard requestID == identity else { return }
                result = value
                loadedRequest = identity
                for user in value.users { app.register(user) }
            } catch {
                guard !Task.isCancelled, requestID == identity else { return }
                self.error = error.localizedDescription
                app.handle(error)
            }
            if !Task.isCancelled { busy = false }
        }
    }

    private var searchFilter: some View {
        let label = titleOnly ? titleFilterLabel : order == .relevance ? "筛选" : order.label
        return Button {
            focused = false
            showFilters = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                if !typeSize.isAccessibilitySize { Text(label) }
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }.font(.subheadline).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                .foregroundStyle(titleOnly || order != .relevance ? Color.biliPink : Color.biliMuted)
        }.buttonStyle(.plain)
            .accessibilityLabel("搜索筛选")
            .accessibilityValue(titleOnly ? "\(order.label)，\(titleFilterLabel)" : order.label)
            .accessibilityIdentifier("video-search-filter")
            .popover(isPresented: $showFilters, arrowEdge: .top) {
                VStack(spacing: 0) {
                    ForEach(VideoSearchOrder.allCases, id: \.self) { choice in
                        filterRow(choice.label, selected: order == choice, checkColor: .biliMuted) {
                            if order != choice {
                                page = 1
                                order = choice
                            }
                        }
                    }
                    Divider()
                    filterRow(titleFilterLabel, selected: titleOnly, checkColor: .biliPink,
                              description: "只保留标题包含所有搜索词的视频") {
                        page = 1
                        titleOnly.toggle()
                    }
                }.padding(.horizontal, 12).padding(.vertical, 4).frame(width: 204)
                    .presentationBackground(Color.biliPanel)
                    .presentationCompactAdaptation(.popover)
            }
    }

    private func filterRow(_ label: String, selected: Bool, checkColor: Color, description: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            showFilters = false
            action()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label)
                    Spacer(minLength: 8)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(checkColor).accessibilityHidden(true)
                    }
                }.font(.subheadline)
                if let description {
                    Text(description).font(.caption2).foregroundStyle(Color.biliMuted)
                }
            }.padding(.vertical, description == nil ? 0 : 8).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityHint(description ?? "")
            .accessibilityAddTraits(selected ? .isSelected : [])
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
            TextField("搜索视频、UP 主或 BV 号", text: $text,
                      prompt: Text("搜索视频、UP 主或 BV 号").foregroundStyle(Color.biliPlaceholder))
                .font(.system(size: 14)).submitLabel(.search).focused($focused)
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
                .accessibilityIdentifier("submit-search")
        }.padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 48)
            .background(Color.biliSoft, in: Capsule())
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
