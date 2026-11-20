@testable import NearsideCore
import CryptoKit
import Foundation
import Testing

struct DisplayProtocolTests {
    private func packet(_ type: UInt8, _ body: [UInt8]) -> Data { DisplayWire.packet(type, Data(body)) }

    @Test func parsesFramesAndConfigsAcrossChunkBoundaries() {
        var frame = Data()
        frame.appendBE(UInt32(3)); frame.appendBE(UInt64(1_000)); frame.appendBE(UInt64(1_012)); frame.append(1)
        frame.append(contentsOf: [0, 0, 0, 1, 0x26, 0x01])
        var config = Data()
        config.appendBE(UInt32(3)); config.appendBE(UInt16(1080)); config.appendBE(UInt16(2400))
        config.append(contentsOf: [0, 0, 0, 1, 0x40])
        let stream = DisplayWire.packet(DisplayWire.config, config) + DisplayWire.packet(DisplayWire.frame, frame)

        var reader = DisplayWire.Reader()
        var messages: [DisplayWire.Message] = []
        for byte in stream { messages += reader.feed(Data([byte])) } // worst case: one byte at a time
        #expect(messages == [
            .config(gen: 3, width: 1080, height: 2400, parameterSets: Data([0, 0, 0, 1, 0x40])),
            .frame(gen: 3, ptsMicros: 1_000, encodedMicros: 1_012, keyframe: true, data: Data([0, 0, 0, 1, 0x26, 0x01])),
        ])
    }

    @Test func dropsPacketsTooShortForTheirType() {
        var reader = DisplayWire.Reader()
        let short = packet(DisplayWire.frame, [0, 0, 0, 1]) + packet(DisplayWire.pong, [1, 2, 3])
            + packet(DisplayWire.config, [0]) + packet(DisplayWire.taskGone, [])
            + packet(DisplayWire.taskGone, [1])
        #expect(reader.feed(short) == [.taskGone(.movedToPhone)])
        #expect(!reader.failed)
    }

    @Test func refusesOversizedPackets() {
        var reader = DisplayWire.Reader()
        var huge = Data([DisplayWire.frame, 0])
        huge.appendBE(UInt32(DisplayWire.maxPacket + 1))
        #expect(reader.feed(huge).isEmpty)
        #expect(reader.failed)
        #expect(reader.feed(packet(DisplayWire.taskGone, [0])).isEmpty) // stays failed
    }

    @Test func helloMatchesTheHelpersFormat() {
        let session = Data(repeating: 0xab, count: 16), ticket = Data(repeating: 0x01, count: 32)
        let hello = DisplayWire.hello(role: .video, session: session, ticket: ticket, token: "secret")
        #expect(hello.count == 6 + 87)
        let body = hello.suffix(from: 6)
        #expect(body.prefix(4) == Data("ATD1".utf8))
        #expect(body[body.startIndex + 6] == 2) // role
        let proof = HMAC<SHA256>.authenticationCode(
            for: Data("nearside-display:2:\(session.hexString):\(ticket.hexString)".utf8),
            using: SymmetricKey(data: Data("secret".utf8)))
        #expect(body.suffix(32) == Data(proof))
    }

    @Test func serverHelloCarriesTheHelpersProof() {
        let session = Data(repeating: 7, count: 16), ticket = Data(repeating: 9, count: 32)
        let proof = DisplayWire.serverProof(role: .control, session: session, ticket: ticket, token: "secret")
        var reader = DisplayWire.Reader()
        #expect(reader.feed(DisplayWire.packet(DisplayWire.hello, proof)) == [.serverHello(proof: proof)])
        // It differs from the Mac's own proof, so a captured Mac hello can't be echoed back.
        let mac = DisplayWire.hello(role: .control, session: session, ticket: ticket, token: "secret").suffix(32)
        #expect(Data(mac) != proof)
    }

    @Test func touchEncodesNormalisedCoordinates() {
        let p = DisplayWire.touch(.move, pointer: 0, gen: 7, x: 0.5, y: 0.25, micros: 123_456)
        #expect(p.prefix(2) == Data([DisplayWire.touch, 0]))
        #expect(p.readBE(UInt32.self, at: 2) == 22)
        #expect(p[6] == DisplayWire.TouchAction.move.rawValue)
        #expect(p.readBE(UInt32.self, at: 8) == 7)
        #expect(Float(bitPattern: p.readBE(UInt32.self, at: 12)) == 0.5)
        #expect(Float(bitPattern: p.readBE(UInt32.self, at: 16)) == 0.25)
        #expect(p.readBE(UInt64.self, at: 20) == 123_456)
    }

    @Test func displaySizeKeepsOneDpPerPoint() {
        let phone = PhoneDisplaySize.forWindow(CGSize(width: 400, height: 880), scale: 2)
        #expect(phone.width == 800 && phone.height == 1760 && phone.dpi == 320)
        // A big window is capped (long side 2400 / 2.6 Mpx) and the density follows, so the app's
        // layout in dp is unchanged.
        let big = PhoneDisplaySize.forWindow(CGSize(width: 1400, height: 1000), scale: 2)
        #expect(max(big.width, big.height) <= 2400 && big.width * big.height <= 2_600_000)
        #expect(abs(Double(big.width) / Double(big.dpi) * 160 - 1400) < 8)
        #expect(big.width % 2 == 0 && big.height % 2 == 0)
    }

    @Test func splitsAnnexBIntoNalUnits() {
        let stream = Data([0, 0, 0, 1, 0x40, 0x01, 0, 0, 1, 0x42, 0x01, 0, 0, 0, 1, 0x26])
        #expect(VideoDecoder.nalUnits(stream) == [Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x26])])
    }

    @Test func topBandCropMakesTheDisplayTallerByTheBand() {
        // 400×880 pt window at 2×, a 68 dp band: the display is 68 dp taller and its top 136 px go.
        let s = PhoneDisplaySize.forWindow(CGSize(width: 400, height: 880), scale: 2, cropTopDp: 68)
        #expect(s.width == 800 && s.height == 1896 && s.dpi == 320 && s.cropPixels == 136)
        #expect(s.height - s.cropPixels == 1760) // exactly the window's pixels are shown
        let none = PhoneDisplaySize.forWindow(CGSize(width: 400, height: 880), scale: 2, cropTopDp: 0)
        #expect(none.cropPixels == 0 && none.height == 1760)
    }

    @Test func inputMapsPastTheCroppedBand() {
        #expect(PhoneDisplaySize.displayY(0, cropPixels: 136, height: 1896) == Float(136) / 1896)
        #expect(PhoneDisplaySize.displayY(1, cropPixels: 136, height: 1896) == 1)
        #expect(PhoneDisplaySize.displayY(0.5, cropPixels: 0, height: 1760) == 0.5)
    }
}
