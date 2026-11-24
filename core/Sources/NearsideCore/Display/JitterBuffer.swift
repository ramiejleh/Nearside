/// The audio waiting to be played: a ring of interleaved samples between the network and the
/// output. It starts (and restarts after running dry) once `target` frames are in, and drops the
/// oldest when more than `target + slack` pile up, so delay stays near `target`. The target adapts
/// to the network: it starts at `minTarget` (40 ms), grows by `step` after each underrun (Wi-Fi
/// delivers in bursts: gaps of 80–96 ms about once a second were measured), up to `maxTarget`,
/// and shrinks by `step / 2` after `calm` frames without one. A backlog left by a burst (audio
/// that sat unused for a whole `window`) is trimmed back to the target, so delay doesn't creep up.
public struct JitterBuffer {
    public let channels: Int
    public private(set) var target: Int
    public let minTarget: Int
    public let maxTarget: Int
    public let slack: Int
    public let step: Int
    public let calm: Int
    public let window: Int
    public var limit: Int { target + slack }
    private var samples: [Float]
    private var read = 0
    private var count = 0
    private var playedSinceUnderrun = 0
    private var playedInWindow = 0
    private var lowWater = Int.max
    public private(set) var playing = false
    public private(set) var underruns = 0
    public private(set) var dropped = 0
    /// The phone said silence follows: running dry then isn't a network hiccup.
    private var ending = false

    /// All in frames.
    public init(channels: Int, minTarget: Int, maxTarget: Int, slack: Int, step: Int, calm: Int, window: Int) {
        self.channels = channels
        self.target = minTarget
        self.minTarget = minTarget
        self.maxTarget = maxTarget
        self.slack = slack
        self.step = step
        self.calm = calm
        self.window = window
        samples = [Float](repeating: 0, count: (maxTarget + slack) * channels * 2)
    }

    /// For a sample rate: 40…200 ms, 100 ms of slack, steps of 20 ms, calm after 30 s (shrinking
    /// sooner just brought the next underrun: this Wi-Fi had ~80 ms gaps every few seconds), 2 s windows.
    public init(channels: Int, sampleRate: Int) {
        let ms = sampleRate / 1000
        self.init(channels: channels, minTarget: 40 * ms, maxTarget: 200 * ms, slack: 100 * ms, step: 20 * ms,
                  calm: 30 * sampleRate, window: 2 * sampleRate)
    }

    public var buffered: Int { count / channels }

    /// Silence follows (the phone stops sending): play out what's here, then wait without
    /// counting it as an underrun (that would grow the delay for nothing).
    public mutating func endOfSound() { ending = true }

    public mutating func write(_ new: [Float]) {
        ending = false
        for sample in new {
            if count == samples.count { read = (read + 1) % samples.count; count -= 1 }
            samples[(read + count) % samples.count] = sample
            count += 1
        }
        if buffered > limit {
            let drop = (buffered - target) * channels
            read = (read + drop) % samples.count
            count -= drop
            dropped += drop / channels
        }
        if !playing, buffered >= target { playing = true }
    }

    /// Fills `out` (interleaved, `frames` frames): with audio while playing, silence while
    /// waiting to fill up again.
    public mutating func read(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let wanted = frames * channels
        guard playing else {
            out.update(repeating: 0, count: wanted)
            return
        }
        let n = min(wanted, count)
        for i in 0..<n { out[i] = samples[(read + i) % samples.count] }
        read = (read + n) % samples.count
        count -= n
        if n < wanted {
            (out + n).update(repeating: 0, count: wanted - n)
            playing = false
            if ending { ending = false; return } // the sound ended: not the network's fault
            underruns += 1
            target = min(target + step, maxTarget)
            playedSinceUnderrun = 0
            playedInWindow = 0
            lowWater = .max
        } else {
            playedSinceUnderrun += frames
            if playedSinceUnderrun >= calm {
                target = max(target - step / 2, minTarget)
                playedSinceUnderrun = 0
            }
            lowWater = min(lowWater, buffered)
            playedInWindow += frames
            if playedInWindow >= window {
                // Never dipped below lowWater all window: the part above the target is only delay.
                if lowWater > target + step / 2 {
                    let drop = (lowWater - target) * channels
                    read = (read + drop) % samples.count
                    count -= drop
                    dropped += drop / channels
                }
                playedInWindow = 0
                lowWater = .max
            }
        }
    }
}
