import AppKit
import SwiftUI

struct MenuBarCapsuleIcon: View {
  let showsIssue: Bool
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if showsIssue {
      Image(systemName: "exclamationmark.circle.fill")
    } else {
      Image(nsImage: colorScheme == .dark ? Self.whiteCapsuleImage : Self.blackCapsuleImage)
        .renderingMode(.original)
        .frame(width: 18, height: 18)
    }
  }

  private static let whiteCapsuleImage = capsuleImage(color: .white)
  private static let blackCapsuleImage = capsuleImage(color: .black)

  private static func capsuleImage(color: NSColor) -> NSImage {
    guard let representation = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 36,
      pixelsHigh: 36,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
      return NSImage(size: NSSize(width: 18, height: 18))
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    let context = graphicsContext.cgContext
    context.translateBy(x: 0, y: 36)
    context.scaleBy(x: 36 / 1024, y: -36 / 1024)

    color.setFill()
    capsulePath(half: .upper).fill()

    color.withAlphaComponent(0.6).setFill()
    capsulePath(half: .lower).fill()
    NSGraphicsContext.restoreGraphicsState()

    representation.size = NSSize(width: 18, height: 18)
    let image = NSImage(size: NSSize(width: 18, height: 18))
    image.addRepresentation(representation)
    image.isTemplate = false
    return image
  }

  private enum CapsuleHalf {
    case upper
    case lower
  }

  private static func iconPoint(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    let artworkScale: CGFloat = 1.4
    return NSPoint(
      x: 512 + (x - 512) * artworkScale,
      y: 512 + (y - 512) * artworkScale
    )
  }

  private static func capsulePath(half: CapsuleHalf) -> NSBezierPath {
    let path = NSBezierPath()
    switch half {
    case .upper:
      path.move(to: iconPoint(424.32, 394.62))
      path.line(to: iconPoint(537.47, 281.47))
      path.curve(
        to: iconPoint(742.53, 281.47),
        controlPoint1: iconPoint(594.09, 224.85),
        controlPoint2: iconPoint(685.91, 224.85)
      )
      path.curve(
        to: iconPoint(742.53, 486.53),
        controlPoint1: iconPoint(799.15, 338.09),
        controlPoint2: iconPoint(799.15, 429.91)
      )
      path.line(to: iconPoint(629.38, 599.68))
    case .lower:
      path.move(to: iconPoint(394.62, 424.32))
      path.line(to: iconPoint(281.47, 537.47))
      path.curve(
        to: iconPoint(281.47, 742.53),
        controlPoint1: iconPoint(224.85, 594.09),
        controlPoint2: iconPoint(224.85, 685.91)
      )
      path.curve(
        to: iconPoint(486.53, 742.53),
        controlPoint1: iconPoint(338.09, 799.15),
        controlPoint2: iconPoint(429.91, 799.15)
      )
      path.line(to: iconPoint(599.68, 629.38))
    }
    path.close()
    return path
  }
}
