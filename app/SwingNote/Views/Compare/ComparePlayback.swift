import AVFoundation
import Observation
import SwiftUI
import UIKit

/// 2球をインパクト時刻で揃えて同時に再生する。
/// time はインパクトからの相対秒（負ならインパクト前）。
/// クリップがない時（プレビュー）は時計だけを進めて、UI の動きを確かめられるようにする。
@MainActor
@Observable
final class ComparePlayback {
    let a: ClipInfo
    let b: ClipInfo
    let range: ClosedRange<Double>

    private(set) var time: Double
    private(set) var isPlaying = false
    private(set) var isSlow = false

    let playerA = AVPlayer()
    let playerB = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var loadedTinted: Bool?

    var hasVideo: Bool { a.url != nil && b.url != nil }

    init(a: ClipInfo, b: ClipInfo) {
        self.a = a
        self.b = b
        let lower = -min(a.impact, b.impact)
        let upper = min(a.duration - a.impact, b.duration - b.impact)
        range = lower...max(upper, lower + 0.1)
        time = lower
        for player in [playerA, playerB] {
            // setRate(_:time:atHostTime:) で2本を同時に動かすため
            player.automaticallyWaitsToMinimizeStalling = false
        }
        // 2本の音が重なるので B は消音
        playerB.isMuted = true
    }

    /// tinted は重ね合わせの時だけ true（A を寒色、B を暖色にする）
    func load(tinted: Bool) async {
        guard hasVideo, loadedTinted != tinted, let urlA = a.url, let urlB = b.url else { return }
        pause()
        async let itemA = TintedPlayerItem.make(url: urlA, tint: tinted ? .cold : nil)
        async let itemB = TintedPlayerItem.make(url: urlB, tint: tinted ? .warm : nil)
        let (newA, newB) = await (itemA, itemB)
        playerA.replaceCurrentItem(with: newA)
        playerB.replaceCurrentItem(with: newB)
        loadedTinted = tinted
        installTimeObserver()
        seek(to: time)
    }

    func teardown() {
        pause()
        if let timeObserver { playerA.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playerA.replaceCurrentItem(with: nil)
        playerB.replaceCurrentItem(with: nil)
        loadedTinted = nil
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        if time >= range.upperBound - 0.02 { time = range.lowerBound }
        isPlaying = true
        let rate: Float = isSlow ? UIConfig.slowPlaybackRate : 1
        if hasVideo {
            let start = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.05, preferredTimescale: 600))
            playerA.setRate(rate, time: cmTime(a.impact + time), atHostTime: start)
            playerB.setRate(rate, time: cmTime(b.impact + time), atHostTime: start)
        } else {
            runClock(rate: Double(rate))
        }
    }

    func pause() {
        isPlaying = false
        clockTask?.cancel()
        clockTask = nil
        playerA.pause()
        playerB.pause()
    }

    func toggleSlow() {
        isSlow.toggle()
        if isPlaying { play() }
    }

    func seek(to newTime: Double) {
        pause()
        time = min(max(newTime, range.lowerBound), range.upperBound)
        guard hasVideo else { return }
        playerA.seek(to: cmTime(a.impact + time), toleranceBefore: .zero, toleranceAfter: .zero)
        playerB.seek(to: cmTime(b.impact + time), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// コマ送り。frames が負なら戻る
    func step(frames: Int) {
        seek(to: time + Double(frames) / Double(CaptureConfig.current.frameRate))
    }

    /// A 側のチェックポイントのうち、今の時刻までに通過した最後のもの
    var currentCheckpoint: Checkpoint? {
        Checkpoint.allCases.last { checkpoint in
            guard let t = a.checkpoints[checkpoint] else { return false }
            return t - a.impact <= time + 0.001
        }
    }

    /// シークバーの目盛り（0〜1）
    var checkpointMarks: [Double] {
        Checkpoint.allCases.compactMap { checkpoint in
            a.checkpoints[checkpoint].map { (($0 - a.impact) - range.lowerBound) / (range.upperBound - range.lowerBound) }
        }
        .filter { (0...1).contains($0) }
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func installTimeObserver() {
        if let timeObserver { playerA.removeTimeObserver(timeObserver) }
        let impact = a.impact
        timeObserver = playerA.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] current in
            MainActor.assumeIsolated {
                self?.tick(current.seconds - impact)
            }
        }
    }

    private func tick(_ newTime: Double) {
        guard isPlaying else { return }
        time = min(newTime, range.upperBound)
        if newTime >= range.upperBound { pause() }
    }

    private func runClock(rate: Double) {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.isPlaying else { return }
                let next = self.time + 0.033 * rate
                self.time = min(next, self.range.upperBound)
                if next >= self.range.upperBound { self.pause() }
            }
        }
    }
}

/// AVPlayerLayer をそのまま置くためのビュー（VideoPlayer は標準の操作 UI が付くので使わない）
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
