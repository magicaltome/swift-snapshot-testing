#if os(iOS) || os(tvOS)
import UIKit
import XCTest

extension Diffing where Value == UIImage {
  /// A pixel-diffing strategy for UIImage's which requires a 100% match.
  public static let image = Diffing.image(precision: 1, scale: nil)

  /// A pixel-diffing strategy for UIImage that allows customizing how precise the matching must be.
  ///
  /// - Parameter precision: A value between 0 and 1, where 1 means the images must match 100% of their pixels.
  /// - Parameter scale: Scale to use when loading the reference image from disk. If `nil` or the `UITraitCollection`s default value of `0.0`, the screens scale is used.
  /// - Returns: A new diffing strategy.
  public static func image(precision: Float, scale: CGFloat?) -> Diffing {
    let imageScale: CGFloat
    if let scale = scale, scale != 0.0 {
      imageScale = scale
    } else {
      imageScale = UIScreen.main.scale
    }

    return Diffing(
      toData: { $0.pngData() ?? emptyImage().pngData()! },
      fromData: { UIImage(data: $0, scale: imageScale)! }
    ) { old, new in
      var message = ""
      switch compare(old, new, precision: precision) {
      case .invalid:
        message = new.size == old.size
          ? "Newly-taken snapshot does not match reference."
          : "Newly-taken snapshot@\(new.size) does not match reference@\(old.size)."
      case .different(let pixelCount, let differentPixelCount):
        message = new.size == old.size
          ? "Newly-taken snapshot does not match reference. Pixel difference \(differentPixelCount)px (\(Float(differentPixelCount) / Float(pixelCount) * 100)%)"
          : "Newly-taken snapshot@\(new.size) does not match reference@\(old.size). Pixel difference \(differentPixelCount)px (\(Float(differentPixelCount) / Float(pixelCount) * 100)%)"
      case .same:
        return nil
      }
      let difference = SnapshotTesting.diff(old, new)
      let oldAttachment = XCTAttachment(image: old)
      oldAttachment.name = "reference"
      let newAttachment = XCTAttachment(image: new)
      newAttachment.name = "failure"
      let differenceAttachment = XCTAttachment(image: difference)
      differenceAttachment.name = "difference"
      return (
        message,
        [oldAttachment, newAttachment, differenceAttachment]
      )
    }
  }
  
  
  /// Used when the image size has no width or no height to generated the default empty image
  private static func emptyImage() -> UIImage {
    let label = UILabel(frame: CGRect(x: 0, y: 0, width: 400, height: 80))
    label.backgroundColor = .red
    label.text = "Error: No image could be generated for this view as its size was zero. Please set an explicit size in the test."
    label.textAlignment = .center
    label.numberOfLines = 3
    return label.asImage()
  }
}

extension Snapshotting where Value == UIImage, Format == UIImage {
  /// A snapshot strategy for comparing images based on pixel equality.
  public static var image: Snapshotting {
    return .image(precision: 1, scale: nil)
  }

  /// A snapshot strategy for comparing images based on pixel equality.
  ///
  /// - Parameter precision: The percentage of pixels that must match.
  /// - Parameter scale: The scale of the reference image stored on disk.
  public static func image(precision: Float, scale: CGFloat?) -> Snapshotting {
    return .init(
      pathExtension: "png",
      diffing: .image(precision: precision, scale: scale)
    )
  }
}

// remap snapshot & reference to same colorspace
let imageContextColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
let imageContextBitsPerComponent = 8
let imageContextBytesPerPixel = 4

enum CompareResult {
  case different(pixelCount: Int, differentPixelCount: Int)
  case invalid
  case same
}

private func compare(_ old: UIImage, _ new: UIImage, precision: Float) -> (CompareResult) {
  guard let oldCgImage = old.cgImage else { return .invalid }
  guard let newCgImage = new.cgImage else { return .invalid }
  guard oldCgImage.width != 0 else { return .invalid }
  guard newCgImage.width != 0 else { return .invalid }
  guard oldCgImage.width == newCgImage.width else { return .invalid }
  guard oldCgImage.height != 0 else { return .invalid }
  guard newCgImage.height != 0 else { return .invalid }
  guard oldCgImage.height == newCgImage.height else { return .invalid }

  let byteCount = imageContextBytesPerPixel * oldCgImage.width * oldCgImage.height
  var oldBytes = [UInt8](repeating: 0, count: byteCount)
  guard let oldContext = context(for: oldCgImage, data: &oldBytes) else { return .invalid }
  guard let oldData = oldContext.data else { return .invalid }
  if let newContext = context(for: newCgImage), let newData = newContext.data {
    if memcmp(oldData, newData, byteCount) == 0 { return .same }
  }
  let newer = UIImage(data: new.pngData()!)!
  guard let newerCgImage = newer.cgImage else { return .invalid }
  var newerBytes = [UInt8](repeating: 0, count: byteCount)
  guard let newerContext = context(for: newerCgImage, data: &newerBytes) else { return .invalid }
  guard let newerData = newerContext.data else { return .invalid }
  if memcmp(oldData, newerData, byteCount) == 0 { return .same }
  var differentPixelCount = 0
  let threshold = 1 - precision
  for byte in 0..<byteCount {
    if oldBytes[byte] != newerBytes[byte] { differentPixelCount += 1 }
  }
  if Float(differentPixelCount) / Float(byteCount) > threshold { return .different(pixelCount: byteCount, differentPixelCount: differentPixelCount)}
  return .same
}

private func context(for cgImage: CGImage, data: UnsafeMutableRawPointer? = nil) -> CGContext? {
  let bytesPerRow = cgImage.width * imageContextBytesPerPixel
  guard
    let colorSpace = imageContextColorSpace,
    let context = CGContext(
      data: data,
      width: cgImage.width,
      height: cgImage.height,
      bitsPerComponent: imageContextBitsPerComponent,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    else { return nil }

  context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
  return context
}

private func diff(_ old: UIImage, _ new: UIImage) -> UIImage {
  let width = max(old.size.width, new.size.width)
  let height = max(old.size.height, new.size.height)
  let scale = max(old.scale, new.scale)
  UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, scale)
  new.draw(at: .zero)
  old.draw(at: .zero, blendMode: .difference, alpha: 1)
  let differenceImage = UIGraphicsGetImageFromCurrentImageContext()!
  UIGraphicsEndImageContext()
  return differenceImage
}
#endif
