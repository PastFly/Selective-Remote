import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count == 2,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("RDP_PATTERN_BLOCKED: screenshot unavailable\n", stderr); exit(2)
}
let width = image.width, height = image.height
guard width > 0, height > 0, width <= 8192, height <= 8192 else { exit(2) }
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
    guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard rendered else { fputs("RDP_PATTERN_BLOCKED: image decode failed\n", stderr); exit(2) }
// The test server paints large red, green and blue bars. Requiring all three
// on the same scanline rejects an opened or merely connecting window.
for y in stride(from: 0, to: height, by: 3) {
    var counts = [0, 0, 0]
    for x in stride(from: 0, to: width, by: 2) {
        let at = (y * width + x) * 4
        let channels = [pixels[at], pixels[at + 1], pixels[at + 2]]
        for i in 0..<3 where channels[i] > 191 && channels[(i+1)%3] < 64 && channels[(i+2)%3] < 64 { counts[i] += 1 }
    }
    if counts.allSatisfy({ $0 >= 50 }) {
        print("SYNTHETIC_RDP_PATTERN_RENDERED=YES")
        exit(0)
    }
}
fputs("RDP_PATTERN_BLOCKED: expected color bars not rendered\n", stderr)
exit(1)
