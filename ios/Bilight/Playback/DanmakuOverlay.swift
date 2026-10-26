import AVFoundation
import UIKit

struct Danmaku: Equatable {
    var id: Int
    var time: Double
    var text: String
    var mode: Int
    var color: UInt32
    static func parse(_ data: Data) throws -> [Danmaku] {
        guard data.count <= 8_000_000, let xml = String(data: data, encoding: .utf8),
            !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY")
        else { throw BiliFailure.invalid }
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.root else { throw BiliFailure.invalid }
        return delegate.items.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }
    private final class Parser: NSObject, XMLParserDelegate {
        var items: [Danmaku] = [], root = false
        private var parameters: [String]?, text = ""
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            if elementName == "i" { root = true }
            if elementName == "d" { parameters = attributeDict["p"]?.components(separatedBy: ","); text = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if parameters != nil { text += String(string.prefix(max(0, 600 - text.count))) } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard elementName == "d", let p = parameters else { return }
            defer { parameters = nil }
            guard items.count < 10000, p.count >= 4, let time = Double(p[0]), time.isFinite, (0..<86400).contains(time), let mode = Int(p[1]), [1, 4, 5, 6].contains(mode), let color = UInt32(p[3]), color <= 0xffffff else { return }
            let value = clean(text, limit: 300)
            if !value.isEmpty { items.append(Danmaku(id: items.count, time: time, text: value, mode: mode, color: color)) }
        }
    }
}

/// Own display link and bounded text layers keep animation out of SwiftUI's page update cycle.
@MainActor final class DanmakuOverlay: UIView {
    weak var player: AVPlayer?
    private var items: [Danmaku] = []
    private var labels: [Int: UILabel] = [:]
    private var link: CADisplayLink?
    private var revision: UUID?
    private var fontSize: CGFloat = 20
    private var lastTime = Double.nan
    private var lastSize = CGSize.zero
    func update(player: AVPlayer, items: [Danmaku], enabled: Bool, revision: UUID, fontSize: CGFloat = 20, opacity: CGFloat = 1) {
        self.player = player
        let fontSize = min(24, max(16, fontSize))
        if self.fontSize != fontSize { self.fontSize = fontSize; clear() }
        alpha = min(1, max(0.5, opacity))
        if self.revision != revision { self.revision = revision; self.items = items; lastTime = .nan; clear() }
        isHidden = !enabled
        if enabled && window != nil { start() } else { stop() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && !isHidden { start() } else { stop() }
    }
    private func start() {
        guard link == nil, !items.isEmpty else { return }
        let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common); self.link = link
    }
    private func clear() { labels.values.forEach { $0.removeFromSuperview() }; labels = [:]; lastTime = .nan; lastSize = .zero }
    private func stop() { link?.invalidate(); link = nil; clear() }
    fileprivate func tick() {
        guard let time = player?.currentTime().seconds, time.isFinite, bounds.width > 0 else { return }
        if time == lastTime && bounds.size == lastSize { return }
        lastTime = time; lastSize = bounds.size
        var low = 0, high = items.count
        while low < high { let middle = (low + high) / 2; if items[middle].time < time - 8 { low = middle + 1 } else { high = middle } }
        var visible: [Danmaku] = []
        var index = low
        while index < items.count && items[index].time <= time && visible.count < 40 {
            let item = items[index]
            if time - item.time < (item.mode == 4 || item.mode == 5 ? 4 : 8) { visible.append(item) }
            index += 1
        }
        let ids = Set(visible.map(\.id))
        for id in Array(labels.keys) where !ids.contains(id) { labels.removeValue(forKey: id)?.removeFromSuperview() }
        var occupied = Set<Int>()
        let lanes = max(1, min(7, Int(bounds.height / 32) - 1))
        for item in visible {
            let lane = item.id % lanes
            // Bound density in each lane instead of stacking unreadable text.
            if occupied.contains(lane) { labels.removeValue(forKey: item.id)?.removeFromSuperview(); continue }
            occupied.insert(lane)
            let label: UILabel
            if let existing = labels[item.id] { label = existing }
            else {
                label = UILabel(); label.font = .systemFont(ofSize: fontSize, weight: .semibold)
                let color = UIColor(red: CGFloat((item.color >> 16) & 255)/255, green: CGFloat((item.color >> 8) & 255)/255, blue: CGFloat(item.color & 255)/255, alpha: 1)
                label.attributedText = NSAttributedString(string: item.text, attributes: [.foregroundColor: color, .strokeColor: UIColor.black.withAlphaComponent(0.8), .strokeWidth: -2])
                label.sizeToFit(); addSubview(label); labels[item.id] = label
            }
            let elapsed = time - item.time
            let fixed = item.mode == 4 || item.mode == 5
            let x = fixed ? (bounds.width-label.bounds.width)/2 : item.mode == 6 ? -label.bounds.width+(bounds.width+label.bounds.width)*elapsed/8 : bounds.width-(bounds.width+label.bounds.width)*elapsed/8
            let y = item.mode == 4 ? bounds.height-CGFloat(lane+1)*30-25 : 12+CGFloat(lane)*30
            label.frame.origin = CGPoint(x: x, y: max(5, y))
        }
    }
    @MainActor private final class WeakTarget: NSObject {
        weak var overlay: DanmakuOverlay?
        init(_ overlay: DanmakuOverlay) { self.overlay = overlay }
        @objc func tick() { overlay?.tick() }
    }
    deinit { link?.invalidate() }
}
