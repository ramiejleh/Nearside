import Foundation
import NearsideCore
import SpikePlatform

// The engine in a console, for Phase 3: the same SyncEngine as the Mac app, with a minimal
// platform (SpikePlatform: the Windows clipboard; no video or sound).
//   nearside-engine pair <ip:port> <code> [apk]   set up: pair, install the phone app, start the helper
//   nearside-engine                               run: connect, sync the clipboard, print what happens

Platforms.current = SpikePlatform()
setvbuf(stdout, nil, _IONBF, 0) // unbuffered: Windows rejects line buffering with no size
let args = CommandLine.arguments.dropFirst().map { $0 }

MainActor.assumeIsolated {
    let apk = args.count >= 4 ? URL(fileURLWithPath: args[3]) : nil
    let engine = SyncEngine(apkURL: apk)
    engine.onArrival = { item in print("clip from the phone: \(item.text.count) characters") }
    engine.start()
    if args.first == "pair", args.count >= 3 { engine.pair(hostPort: args[1], code: args[2]) }
    var lastState = "", lastSteps = ""
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        MainActor.assumeIsolated {
            let state = "\(engine.state)\(engine.appLinked ? ", phone app linked" : "")"
            if state != lastState { lastState = state; print("state: \(state) (\(engine.phoneName))") }
            let steps = engine.setupSteps.map { "\($0.title): \($0.status)" }.joined(separator: "\n  ")
            if steps != lastSteps { lastSteps = steps; if !steps.isEmpty { print("setup:\n  \(steps)") } }
        }
    }
}
RunLoop.main.run()
