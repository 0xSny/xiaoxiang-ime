import UIKit
import AVFoundation
import AudioToolbox

/// Haptics: generators are kept alive and re-prepared right after every trigger so the Taptic Engine
/// is always warm (rigid, crisp taps).
final class HapticEngine {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let selection = UISelectionFeedbackGenerator()
    var level: Int = 2   // 0 off, 1 light, 2 crisp, 3 strong

    func prepare() {
        switch level {
        case 1: light.prepare()
        case 2: rigid.prepare()
        case 3: heavy.prepare()
        default: break
        }
        selection.prepare()
    }

    func tap() {
        switch level {
        case 1: light.impactOccurred(intensity: 0.65); light.prepare()
        case 2: rigid.impactOccurred(intensity: 0.7); rigid.prepare()
        case 3: heavy.impactOccurred(intensity: 1.0); heavy.prepare()
        default: break
        }
    }

    func tick() {
        guard level > 0 else { return }
        selection.selectionChanged()
        selection.prepare()
    }
}

/// Low-latency key click. Uses a short synthesized buffer on an ambient, mix-with-others session so
/// background music/video is never paused or ducked. Falls back to the system keyboard click sounds.
final class ClickPlayer {
    enum Kind: Int { case key = 0, delete, space }

    var enabled = true
    var volume: Float = 0.6 { didSet { node?.volume = volume } }

    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var buffers: [AVAudioPCMBuffer] = []
    private var failed = false

    /// Must be called from a user gesture (first touch).
    func warmUp() {
        guard enabled, engine == nil, !failed else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let e = AVAudioEngine()
            let n = AVAudioPlayerNode()
            e.attach(n)
            e.connect(n, to: e.mainMixerNode, format: format)
            buffers = [makeClick(format, freq: 2100, decay: 260), makeClick(format, freq: 1250, decay: 220),
                       makeClick(format, freq: 1650, decay: 240)]
            n.volume = volume
            try e.start()
            n.play()
            engine = e
            node = n
        } catch {
            failed = true
            engine = nil
            node = nil
        }
    }

    func play(_ kind: Kind) {
        guard enabled, volume > 0.001 else { return }
        if let node = node, engine != nil, !buffers.isEmpty {
            node.scheduleBuffer(buffers[kind.rawValue], at: nil, options: .interrupts, completionHandler: nil)
            if !node.isPlaying { node.play() }
            return
        }
        if failed || engine == nil {
            let ids: [SystemSoundID] = [1104, 1155, 1156]
            AudioServicesPlaySystemSound(ids[kind.rawValue])
        }
    }

    func shutDown() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
    }

    private func makeClick(_ format: AVAudioFormat, freq: Double, decay: Double) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate * 0.028)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        var seed: UInt32 = 12345
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let env = exp(-t * decay)
            seed = seed &* 1664525 &+ 1013904223
            let noise = (Double(seed >> 9) / Double(1 << 23) - 0.5) * (t < 0.0012 ? 1.0 : 0.0)
            let tone = sin(2 * Double.pi * freq * t) * 0.8 + sin(2 * Double.pi * freq * 2.7 * t) * 0.25
            p[i] = Float((tone * env + noise * 0.6) * 0.55)
        }
        return buf
    }
}
