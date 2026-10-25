import AppKit

let size = CGSize(width: 1024, height: 1024)
let context = CGContext(
    data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.98, green: 0.44, blue: 0.60, alpha: 1))
context.fill(CGRect(origin: .zero, size: size))
context.setStrokeColor(CGColor(gray: 1, alpha: 1))
context.setLineWidth(44)
context.setLineCap(.round)
context.addPath(
    CGPath(
        roundedRect: CGRect(x: 220, y: 270, width: 584, height: 420), cornerWidth: 88, cornerHeight: 88, transform: nil)
)
context.strokePath()
context.move(to: CGPoint(x: 392, y: 710))
context.addLine(to: CGPoint(x: 335, y: 792))
context.move(to: CGPoint(x: 632, y: 710))
context.addLine(to: CGPoint(x: 690, y: 792))
context.strokePath()
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.move(to: CGPoint(x: 454, y: 397))
context.addLine(to: CGPoint(x: 454, y: 570))
context.addLine(to: CGPoint(x: 608, y: 484))
context.closePath()
context.fillPath()
let image = NSBitmapImageRep(cgImage: context.makeImage()!)
try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
