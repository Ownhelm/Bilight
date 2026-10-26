import SwiftUI

// Original paths following the solid thumb / 币 / rounded star silhouettes in the supplied B站 reference.
struct BiliActionIcon: View {
    enum Kind { case like, coin, favorite, download }
    var kind: Kind
    var size: CGFloat = 22
    var body: some View {
        Group {
            switch kind {
            case .like:
                ThumbShape().fill()
            case .coin:
                Circle().fill().overlay { Text("币").font(.system(size: size * 15 / 22, weight: .regular)).foregroundStyle(.white) }
            case .favorite:
                RoundedStar().fill()
            case .download:
                DownloadShape().fill().overlay {
                    Image(systemName: "arrow.down").font(.system(size: size * 12 / 22, weight: .bold)).foregroundStyle(.white).offset(y: size / 22)
                }
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
    // Match visible ink bounds, rather than assigning unequal silhouettes the same nominal canvas.
    private static func fitted(_ path: Path, to rect: CGRect) -> Path {
        let bounds = path.cgPath.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        let sx = rect.width / bounds.width, sy = rect.height / bounds.height
        return path.applying(CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
            tx: rect.minX - bounds.minX * sx, ty: rect.minY - bounds.minY * sy))
    }
    private struct DownloadShape: Shape {
        func path(in rect: CGRect) -> Path {
            let sx = rect.width / 36, sy = rect.height / 36
            var p = Path()
            p.addRoundedRect(in: CGRect(x: sx, y: 7*sy, width: 34*sx, height: 26*sy), cornerSize: CGSize(width: 5*sx, height: 5*sy))
            p.addRoundedRect(in: CGRect(x: 8*sx, y: 3*sy, width: 12*sx, height: 10*sy), cornerSize: CGSize(width: 3*sx, height: 3*sy))
            return p
        }
    }
    private struct ThumbShape: Shape {
        func path(in rect: CGRect) -> Path {
            let sx = rect.width / 36, sy = rect.height / 36
            var p = Path()
            p.addRoundedRect(in: CGRect(x: 2*sx, y: 15*sy, width: 6*sx, height: 18*sy), cornerSize: CGSize(width: 1.8*sx, height: 1.8*sy))
            p.move(to: CGPoint(x: 11*sx, y: 15*sy))
            p.addCurve(to: CGPoint(x: 18*sx, y: 4*sy), control1: CGPoint(x: 16*sx, y: 9*sy), control2: CGPoint(x: 16*sx, y: 8*sy))
            p.addCurve(to: CGPoint(x: 24*sx, y: 7*sy), control1: CGPoint(x: 19*sx, y: 0), control2: CGPoint(x: 24*sx, y: 2*sy))
            p.addLine(to: CGPoint(x: 23*sx, y: 14*sy)); p.addLine(to: CGPoint(x: 31*sx, y: 14*sy))
            p.addQuadCurve(to: CGPoint(x: 34*sx, y: 19*sy), control: CGPoint(x: 35*sx, y: 14*sy))
            p.addLine(to: CGPoint(x: 31*sx, y: 30*sy))
            p.addQuadCurve(to: CGPoint(x: 27*sx, y: 33*sy), control: CGPoint(x: 30*sx, y: 33*sy))
            p.addLine(to: CGPoint(x: 11*sx, y: 33*sy)); p.closeSubpath()
            return BiliActionIcon.fitted(p, to: rect)
        }
    }
    private struct RoundedStar: Shape {
        func path(in rect: CGRect) -> Path {
            let points = (0..<10).map { i -> CGPoint in
                let a = Double(i) * .pi / 5 - .pi / 2, r = (i % 2 == 0 ? 0.49 : 0.255) * min(rect.width, rect.height)
                return CGPoint(x: rect.midX + cos(a)*r, y: rect.midY + sin(a)*r)
            }
            var p = Path()
            func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x*0.86+b.x*0.14, y: a.y*0.86+b.y*0.14) }
            p.move(to: mix(points[0], points[9]))
            for i in 0..<10 {
                p.addQuadCurve(to: mix(points[i], points[(i+1)%10]), control: points[i])
                p.addLine(to: mix(points[(i+1)%10], points[i]))
            }
            p.closeSubpath(); return BiliActionIcon.fitted(p, to: rect)
        }
    }
}

@MainActor final class LikePressState {
    var onTap: () -> Void = {}
    var onTriple: () -> Void = {}
    var onCharge: (Bool) -> Void = { _ in }
    var canHold: () -> Bool = { true }
    private var task: Task<Void, Never>?
    private var active = false, consumed = false
    private let hold: Duration, charge: Duration
    init(hold: Duration = .milliseconds(500), charge: Duration = .milliseconds(1500)) { self.hold = hold; self.charge = charge }
    func begin() {
        guard !active else { return }
        active = true; consumed = false
        task = Task { @MainActor [weak self] in
            guard let hold = self?.hold else { return }
            do { try await Task.sleep(for: hold) } catch { return }
            guard let self, self.active else { return }
            self.consumed = true
            guard self.canHold() else { self.cancel(); return }
            self.onCharge(true)
            do { try await Task.sleep(for: self.charge) } catch { return }
            guard self.active else { return }
            self.active = false; self.task = nil; self.onCharge(false); self.onTriple()
        }
    }
    func end() {
        let tap = active && !consumed
        active = false; task?.cancel(); task = nil; onCharge(false)
        if tap { onTap() }
    }
    func cancel() { guard active || task != nil else { return }; active = false; consumed = true; task?.cancel(); task = nil; onCharge(false) }
}

struct LikePressTarget: UIViewRepresentable {
    var enabled: Bool
    var label: String
    var onTap: () -> Void
    var onTriple: () -> Void
    var onCharge: (Bool) -> Void
    var canHold: () -> Bool
    func makeUIView(context: Context) -> Control { Control() }
    func updateUIView(_ view: Control, context: Context) {
        view.isUserInteractionEnabled = enabled
        view.accessibilityLabel = label
        view.press.onTap = onTap; view.press.onTriple = onTriple; view.press.onCharge = onCharge; view.press.canHold = canHold
        if !enabled { view.press.cancel() }
    }
    static func dismantleUIView(_ view: Control, coordinator: ()) { view.press.cancel() }
    final class Control: UIControl {
        let press = LikePressState()
        private var origin = CGPoint.zero
        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true; accessibilityTraits = .button
            accessibilityHint = "轻点切换点赞，持续长按并蓄力完成一键三连"
            accessibilityCustomActions = [UIAccessibilityCustomAction(name: "一键三连", target: self, selector: #selector(triple))]
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { origin = touches.first?.location(in: self) ?? .zero; press.begin() }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let point = touches.first?.location(in: self) else { return }
            if hypot(point.x-origin.x, point.y-origin.y) > 22 || !bounds.insetBy(dx: -12, dy: -12).contains(point) { press.cancel() }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { press.end() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { press.cancel() }
        override func accessibilityActivate() -> Bool { press.onTap(); return true }
        @objc private func triple() -> Bool { if press.canHold() { press.onTriple() }; return true }
    }
}
