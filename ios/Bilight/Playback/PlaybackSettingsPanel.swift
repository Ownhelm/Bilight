import SwiftUI

struct PlaybackSettingsPanel: View {
    @ObservedObject var model: PlayerModel
    let onQuality: (Int) -> Void
    let onDanmaku: ((Bool) -> Void)?
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var titleSize = 20.0
    @ScaledMetric(relativeTo: .footnote) private var labelSize = 13.0
    @ScaledMetric(relativeTo: .subheadline) private var chipSize = 14.0
    @State private var shown = false
    @State private var dimmed = false
    @State private var closing = false
    @State private var dragOffset: CGFloat = 0
    @State private var dragBeganAtTop: Bool?
    @State private var optionsBounds = CGRect.zero

    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static let fontSizes: [(String, CGFloat)] = [("小", 16), ("中", 20), ("大", 24)]
    private static let enter = Animation.interpolatingSpring(stiffness: 700, damping: 47.62)
    private static let leave = Animation.interpolatingSpring(stiffness: 3800, damping: 123.29)
    private static let scrim = Animation.interpolatingSpring(stiffness: 1600, damping: 80)

    var subtitleLabel: String {
        if model.subtitleTracks.isEmpty { return "暂不可用" }
        return model.subtitleTracks.first(where: { $0.id == model.selectedSubtitle })?.label ?? "关闭"
    }

    var showsDanmakuStyles: Bool { onDanmaku != nil && model.danmakuEnabled }

    private var dark: Bool { colorScheme == .dark }
    // Match Bilight Android's Material 3 roles and composite the light chip fill against white.
    private var accent: Color { Color(srgb: dark ? 0xF58BAB : 0xD63D6E) }
    private var primaryText: Color { Color(srgb: dark ? 0xECECF2 : 0x1D1B20) }
    private var muted: Color { Color(srgb: dark ? 0xACADB9 : 0x6F7481) }
    private var chipText: Color { dark ? muted : Color(srgb: 0x49454F) }
    private var outline: Color { Color(srgb: dark ? 0x383A45 : 0xCAC4D0) }
    private var selectedFill: Color { Color(srgb: dark ? 0x3C2532 : 0xFBEBF0) }

    var body: some View {
        GeometryReader { geometry in
            let safe = geometry.safeAreaInsets
            let width = geometry.size.width + safe.leading + safe.trailing
            let height = geometry.size.height + safe.top + safe.bottom
            let side = width > height
            let panelWidth = side ? min(360, width * 0.48, max(0, geometry.size.width - 24)) : width
            let maxContentHeight = side ? height - 24 : height - safe.top - safe.bottom
            let contentHeight = optionsBounds.height > 0 ? optionsBounds.height : 320
            let panelHeight = min(contentHeight, max(0, maxContentHeight))
            let radius: CGFloat = side ? 16 : 28
            let shape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: side ? radius : 0,
                bottomTrailingRadius: side ? radius : 0, topTrailingRadius: radius)
            ZStack(alignment: side ? .trailing : .bottom) {
                Color.black.opacity(!side && dimmed ? 0.32 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss(side: side) }
                    .accessibilityHidden(true)

                panelContent
                    .frame(height: panelHeight)
                    .padding(.bottom, side ? 0 : safe.bottom)
                    .frame(width: panelWidth)
                    .background {
                        panelColor(side: side).onTapGesture {}
                    }
                    .clipShape(shape)
                    .shadow(color: side ? .black.opacity(0.2) : .clear, radius: 8, y: 4)
                    .contentShape(shape)
                    .simultaneousGesture(sheetDrag(), including: side ? .subviews : .all)
                    .offset(y: !side && !reduceMotion ? (shown ? dragOffset : panelHeight + safe.bottom) : 0)
                    .opacity(shown || (!side && !reduceMotion) ? 1 : 0)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("player-settings-panel")
                    .accessibilityAction(.escape) { dismiss(side: side) }
                    .padding(.trailing, side ? safe.trailing + 12 : 0)
            }
            // The surface reaches the bottom of the window; its content stays above the home indicator.
            .frame(width: width, height: height)
            .clipped()
            .position(x: width / 2 - safe.leading, y: height / 2 - safe.top)
            .onChange(of: side) {
                dragOffset = 0
                dragBeganAtTop = nil
            }
            .onAppear {
                DispatchQueue.main.async {
                    guard !closing else { return }
                    withAnimation(side || reduceMotion ? nil : Self.enter) { shown = true }
                    withAnimation(reduceMotion ? nil : Self.scrim) { dimmed = true }
                }
            }
        }
    }

    private func panelColor(side: Bool) -> Color {
        if !dark { return Color(srgb: 0xFFFFFF) }
        return Color(srgb: side ? 0x23252E : 0x1E2028)
    }

    private var panelContent: some View {
        ScrollView {
            options
                .padding(.horizontal, 20)
                .onGeometryChange(for: CGRect.self) { bounds in
                    bounds.frame(in: .named("settings-scroll"))
                } action: { bounds in
                    optionsBounds = bounds
                }
        }
        .coordinateSpace(name: "settings-scroll")
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("player-settings-options")
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放设置")
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(primaryText)
                .accessibilityAddTraits(.isHeader)
            group("清晰度") {
                if model.qualityChoices.isEmpty {
                    Text("暂无可用清晰度").font(.system(size: labelSize)).foregroundStyle(muted)
                } else {
                    SettingsChipFlow(spacing: 6) {
                        ForEach(model.qualityChoices) { quality in
                            chip(quality.label, selected: model.playback?.quality == quality.id) { onQuality(quality.id) }
                        }
                    }
                }
            }
            group("倍速") {
                SettingsChipFlow(spacing: 6) {
                    ForEach(Self.rates, id: \.self) { rate in
                        chip("\(rate)×", selected: model.rate == rate) { model.setRate(rate) }
                    }
                }
            }
            group("字幕") {
                if model.subtitleTracks.isEmpty {
                    Text(model.subtitleError ?? "暂无可用字幕").font(.system(size: labelSize)).foregroundStyle(muted)
                } else {
                    SettingsChipFlow(spacing: 6) {
                        chip("关闭", selected: model.selectedSubtitle == nil) { model.selectSubtitle(nil) }
                        ForEach(model.subtitleTracks) { track in
                            chip(track.label, selected: model.selectedSubtitle == track.id) { model.selectSubtitle(track) }
                        }
                    }
                }
            }
            if let onDanmaku {
                Toggle("弹幕", isOn: Binding(get: { model.danmakuEnabled }, set: onDanmaku))
                    .toggleStyle(SettingsSwitchStyle(dark: dark, accent: accent))
                    .foregroundStyle(primaryText)
                    .accessibilityIdentifier("player-settings-danmaku")
                if let error = model.danmakuError {
                    Text(error).font(.system(size: labelSize)).foregroundStyle(accent)
                }
                if showsDanmakuStyles {
                    group("字号") {
                        SettingsChipFlow(spacing: 8) {
                            ForEach(Self.fontSizes, id: \.1) { label, size in
                                chip(label, selected: model.danmakuFontSize == size) { model.danmakuFontSize = size }
                            }
                        }
                    }
                    group("弹幕占比") {
                        SettingsChipFlow(spacing: 6) {
                            ForEach(DanmakuArea.allCases, id: \.self) { area in
                                chip(area.title, selected: model.danmakuArea == area) { model.danmakuArea = area }
                            }
                        }
                    }
                    group("不透明度") {
                        SettingsChipFlow(spacing: 8) {
                            ForEach(PlaybackPreferences.danmakuOpacityOptions, id: \.self) { value in
                                chip("\(Int(value * 100))%", selected: model.danmakuOpacity == value) {
                                    model.danmakuOpacity = value
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: labelSize)).foregroundStyle(muted).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: chipSize, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(selected ? accent : chipText)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .frame(minWidth: 44, minHeight: 32)
                .background(selected ? selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if !selected { RoundedRectangle(cornerRadius: 8).strokeBorder(outline) }
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sheetDrag() -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dragBeganAtTop == nil {
                    dragBeganAtTop = optionsBounds.minY >= -1 && value.translation.height > abs(value.translation.width)
                }
                if dragBeganAtTop == true && !closing { dragOffset = max(0, value.translation.height) }
            }
            .onEnded { value in
                let tracked = dragBeganAtTop == true
                dragBeganAtTop = nil
                if tracked && (dragOffset >= 56 || (dragOffset > 0 && value.velocity.height >= 125)) {
                    dismiss(side: false)
                } else {
                    withAnimation(reduceMotion ? nil : Self.enter) { dragOffset = 0 }
                }
            }
    }

    private func dismiss(side: Bool) {
        guard !closing else { return }
        closing = true
        guard !side, !reduceMotion else { onClose(); return }
        withAnimation(Self.scrim) { dimmed = false }
        withAnimation(Self.leave, completionCriteria: .logicallyComplete) {
            shown = false
        } completion: {
            onClose()
        }
    }
}

private struct SettingsChipFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = rows(subviews, width: proposal.width)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, rows(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.midY),
                          anchor: .leading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat?) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        return subviews.map { item in
            let size = item.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if let width, x > 0, x + size.width > width {
                x = 0
                y += lineHeight
                lineHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            return frame
        }
    }
}

private struct SettingsSwitchStyle: ToggleStyle {
    let dark: Bool
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 8)
                let offOutline = Color(srgb: dark ? 0x858898 : 0x79747E)
                let offFill = Color(srgb: dark ? 0x2D2F3A : 0xF5F6F8)
                Capsule()
                    .fill(configuration.isOn ? accent : offFill)
                    .overlay { if !configuration.isOn { Capsule().strokeBorder(offOutline, lineWidth: 2) } }
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Color(srgb: dark ? 0x3F1528 : 0xFFFFFF) : offOutline)
                            .frame(width: configuration.isOn ? 24 : 16, height: configuration.isOn ? 24 : 16)
                            .padding(.horizontal, configuration.isOn ? 4 : 8)
                    }
                    .frame(width: 52, height: 32)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

private extension Color {
    init(srgb: UInt32) {
        self.init(.sRGB, red: Double((srgb >> 16) & 0xFF) / 255,
                  green: Double((srgb >> 8) & 0xFF) / 255, blue: Double(srgb & 0xFF) / 255)
    }
}
