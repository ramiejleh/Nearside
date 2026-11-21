@testable import NearsideCore
import CoreGraphics
import Testing

struct PhoneSizeTests {
    let phone = CGSize(width: 427, height: 952)

    @Test func phoneIsThePhonesOwnScreen() {
        #expect(PhoneSize.phone.dp(phone: phone) == phone)
        #expect(PhoneSize.tablet.dp(phone: phone).width > PhoneSize.tablet.dp(phone: phone).height)
    }

    @Test func zoomFitsTheScreenAndNeverEnlarges() {
        let big = CGSize(width: 3000, height: 2000)
        #expect(PhoneSize.fittingZoom(phone, chrome: 40, screen: big) == 1)
        // 1440×900 laptop: a phone fits at 0.8 (952 × 0.8 + 40 ≤ 810), a tablet at 0.95.
        let laptop = CGSize(width: 1440, height: 875)
        #expect(PhoneSize.fittingZoom(phone, chrome: 40, screen: laptop) == 0.75)
        #expect(PhoneSize.fittingZoom(CGSize(width: 1280, height: 800), chrome: 40, screen: laptop) == 0.9)
    }

    @Test func displayKeepsTheDpWhateverTheZoom() {
        // The display is the preset's dp at 2 px/dp (capped); the dp size it shows is the same.
        let s = PhoneDisplaySize.forWindow(CGSize(width: 1280, height: 800), scale: 2)
        let dpW = Double(s.width) * 160 / Double(s.dpi)
        #expect(abs(dpW - 1280) < 8)
    }
}
