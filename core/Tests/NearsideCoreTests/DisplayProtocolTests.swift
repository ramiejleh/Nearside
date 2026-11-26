@testable import NearsideCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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

    @Test func openAndCameraOpenCarryTheCodec() {
        // OPEN: u16 w, u16 h, u16 dpi, u8 fps, u32 kbps, u8 codec, utf8 target (the phone's DisplayWire.Open).
        let open = DisplayWire.open(width: 1080, height: 2400, dpi: 420, fps: 60, kbps: 12_000, codec: .h264, target: "home")
        let body = Array(open.dropFirst(6))
        #expect(open[0] == DisplayWire.open)
        #expect(body[0..<11] == [0x04, 0x38, 0x09, 0x60, 0x01, 0xA4, 60, 0, 0, 0x2E, 0xE0])
        #expect(body[11] == 1)
        #expect(String(decoding: body[12...], as: UTF8.self) == "home")
        #expect(DisplayWire.open(width: 1080, height: 2400, dpi: 420, fps: 60, kbps: 12_000, target: "home").dropFirst(6)[6 + 11] == 0)

        // CAMERA_OPEN: u8 facing, u16 w, u16 h, u8 fps, u8 codec.
        #expect(Array(DisplayWire.cameraOpen(front: true, width: 1920, height: 1440, fps: 30).dropFirst(6)) == [1, 0x07, 0x80, 0x05, 0xA0, 30, 0])
        #expect(DisplayWire.cameraOpen(front: false, width: 1920, height: 1440, fps: 30, codec: .h264).last == 1)
        #expect(DisplayWire.version == 2)
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

    @Test func touchesCarryEveryFingerInOnePacket() {
        let p = DisplayWire.touches([(.move, 2, 0.25, 0.5), (.move, 3, 0.75, 0.5)], gen: 9, micros: 1000)
        #expect(p.prefix(2) == Data([DisplayWire.touches, 0]))
        #expect(p.readBE(UInt32.self, at: 2) == 4 + 8 + 1 + 2 * 10)
        #expect(p.readBE(UInt32.self, at: 6) == 9)
        #expect(p.readBE(UInt64.self, at: 10) == 1000)
        #expect(p[18] == 2)
        #expect(p[19] == DisplayWire.TouchAction.move.rawValue && p[20] == 2)
        #expect(Float(bitPattern: p.readBE(UInt32.self, at: 21)) == 0.25)
        #expect(p[29] == DisplayWire.TouchAction.move.rawValue && p[30] == 3)
        #expect(Float(bitPattern: p.readBE(UInt32.self, at: 31)) == 0.75)
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
        #expect(AnnexB.nalUnits(stream) == [Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x26])])
    }

    @Test func parsesTheDisplaysSystemBars() {
        // INSETS: u16 top 204, u16 bottom 72 (the phone's status and gesture bars at 480 dpi).
        var reader = DisplayWire.Reader()
        #expect(reader.feed(packet(DisplayWire.insets, [0x00, 0xCC, 0x00, 0x48]) + packet(DisplayWire.insets, [0]))
            == [.insets(top: 204, bottom: 72)])
    }

    @Test func inputMapsPastTheCroppedBand() {
        #expect(PhoneDisplaySize.displayY(0, cropTop: 136, cropBottom: 0, height: 1896) == Float(136) / 1896)
        #expect(PhoneDisplaySize.displayY(1, cropTop: 136, cropBottom: 0, height: 1896) == 1)
        #expect(PhoneDisplaySize.displayY(0.5, cropTop: 0, cropBottom: 0, height: 1760) == 0.5)
        // The gesture bar's rows at the bottom: the shown part's bottom edge is just above them.
        #expect(PhoneDisplaySize.displayY(1, cropTop: 136, cropBottom: 72, height: 1896) == Float(1896 - 72) / 1896)
        #expect(PhoneDisplaySize.displayY(0, cropTop: 136, cropBottom: 72, height: 1896) == Float(136) / 1896)
    }
}
