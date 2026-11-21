import CoreGraphics

/// The sizes a phone app (or the phone window) can be shown at, in Android dp. A window is one
/// of these, never an arbitrary size: switching re-lays the app out once; zooming (⌘+ / ⌘−) only
/// scales the picture.
public enum PhoneSize: String, CaseIterable, Sendable {
    /// The phone's own screen.
    case phone
    /// An open foldable (Pixel 9 Pro Fold's inner screen): small-tablet, nearly square.
    case foldable
    /// A tablet in landscape (Pixel Tablet).
    case tablet

    public var title: String {
        switch self {
        case .phone: "Phone"
        case .foldable: "Foldable"
        case .tablet: "Tablet"
        }
    }

    public var symbol: String {
        switch self {
        case .phone: "iphone"
        case .foldable: "rectangle.split.2x1"
        case .tablet: "ipad.landscape"
        }
    }

    /// In dp. `phoneDp` is the real phone's screen (portrait).
    public func dp(phone phoneDp: CGSize) -> CGSize {
        switch self {
        case .phone: phoneDp
        case .foldable: CGSize(width: 790, height: 820)
        case .tablet: CGSize(width: 1280, height: 800)
        }
    }

    /// The zoom (window points per dp) that fits `dp` plus `chrome` points of bars on `screen`,
    /// at most 1 (actual size: 1 dp = 1 pt), in steps of 0.05.
    public static func fittingZoom(_ dp: CGSize, chrome: CGFloat, screen: CGSize) -> CGFloat {
        let fit = min(1, screen.width * 0.92 / dp.width, (screen.height * 0.9 - chrome) / dp.height)
        return max(0.3, (fit * 20).rounded(.down) / 20)
    }
}
