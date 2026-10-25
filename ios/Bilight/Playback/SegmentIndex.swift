import Foundation

struct ByteSegment {
    var range: ClosedRange<Int64>
    var duration: Double
    static func range(_ raw: Any?) -> ClosedRange<Int64>? {
        guard let text = raw as? String else { return nil }
        let values = text.split(separator: "-").compactMap { Int64($0) }
        guard values.count == 2, values[0] >= 0, values[1] >= values[0] else { return nil }
        return values[0]...values[1]
    }
    static func parse(_ data: Data, absoluteOffset: Int64, total: Int64) throws -> [ByteSegment] {
        guard absoluteOffset >= 0, total > absoluteOffset, data.count <= 1_000_000,
            Int64(data.count) <= total - absoluteOffset
        else { throw BiliFailure.invalid }
        let bytes = [UInt8](data)
        func uint(_ at: Int, _ count: Int) throws -> UInt64 {
            guard at >= 0, at + count <= bytes.count else { throw BiliFailure.invalid }
            return bytes[at..<(at + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        var box = 0
        while box + 8 <= bytes.count {
            var size = Int(try uint(box, 4))
            var header = 8
            if size == 1 {
                let large = try uint(box + 8, 8)
                guard large <= UInt64(bytes.count - box) else { throw BiliFailure.invalid }
                size = Int(large)
                header = 16
            }
            guard size >= header, size <= bytes.count - box else { throw BiliFailure.invalid }
            let name = String(bytes: bytes[(box + 4)..<(box + 8)], encoding: .ascii)
            if name != "sidx" {
                box += size
                continue
            }
            var p = box + header
            let version = try uint(p, 1)
            guard version <= 1 else { throw BiliFailure.invalid }
            let scale = Double(try uint(p + 8, 4))
            guard scale > 0 else { throw BiliFailure.invalid }
            p += 12
            let numberSize = version == 0 ? 4 : 8
            let first = try uint(p + numberSize, numberSize)
            guard first <= UInt64(Int64.max - absoluteOffset - Int64(box + size)) else { throw BiliFailure.invalid }
            var offset = absoluteOffset + Int64(box + size) + Int64(first)
            p += numberSize * 2 + 2
            let count = Int(try uint(p, 2))
            p += 2
            guard count > 0, count <= 100_000, p + count * 12 <= box + size else { throw BiliFailure.invalid }
            var segments: [ByteSegment] = []
            for _ in 0..<count {
                let reference = try uint(p, 4)
                let length = Int64(reference & 0x7fff_ffff)
                let duration = Double(try uint(p + 4, 4)) / scale
                guard reference & 0x8000_0000 == 0, length > 0, duration > 0, offset >= 0, length <= total - offset
                else { throw BiliFailure.invalid }
                segments.append(ByteSegment(range: offset...(offset + length - 1), duration: duration))
                offset += length
                p += 12
            }
            return segments
        }
        throw BiliFailure.invalid
    }
    static func playlist(_ segments: [ByteSegment], initialization: ClosedRange<Int64>, path: String) -> Data {
        let duration = Int(ceil(segments.map(\.duration).max() ?? 1))
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(duration)", "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"\(path)\",BYTERANGE=\"\(initialization.upperBound - initialization.lowerBound + 1)@\(initialization.lowerBound)\"",
        ]
        for segment in segments {
            lines += [
                String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), segment.duration),
                "#EXT-X-BYTERANGE:\(segment.range.upperBound - segment.range.lowerBound + 1)@\(segment.range.lowerBound)",
                path,
            ]
        }
        lines.append("#EXT-X-ENDLIST")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
