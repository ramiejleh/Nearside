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
        #expect(PhoneSize.fittingZoom(phone, chrome: CGSize(width: 44, height: 40), screen: big) == 1)
        // 1440×900 laptop: a phone fits at 0.8 (952 × 0.8 + 40 ≤ 810), a tablet at 0.95.
        let laptop = CGSize(width: 1440, height: 875)
        #expect(PhoneSize.fittingZoom(phone, chrome: CGSize(width: 44, height: 40), screen: laptop) == 0.75)
        #expect(PhoneSize.fittingZoom(CGSize(width: 1280, height: 800), chrome: CGSize(width: 44, height: 40), screen: laptop) == 0.9)
    }

    @Test func displaysUseThePhonesDensity() {
        // Every size at the phone's 480 dpi: the phone size is the phone's own pixels.
        let p = PhoneDisplaySize.forPreset(phone, density: 480)
        #expect(p.width == 1280 && p.height == 2856 && p.dpi == 480 && p.cropPixels == 0)
        let t = PhoneDisplaySize.forPreset(PhoneSize.tablet.dp(phone: phone), density: 480)
        #expect(t.width == 3840 && t.height == 2400 && t.dpi == 480)
        // A 68 dp band cropped off the top: the display is that much taller, all of it cropped.
        let c = PhoneDisplaySize.forPreset(phone, density: 480, cropTopDp: 68)
        #expect(c.cropPixels == 204 && c.height == 2856 + 204)
    }
}
