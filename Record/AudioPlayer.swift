import AVFoundation
import SwiftUI

/// Plays a conversation's audio, with the time for the scrubber and the transcript.
@MainActor @Observable
final class AudioPlayer {
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var playing = false
    /// True once anything has played, so the transcript highlights the line only then.
    private(set) var started = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func load(_ url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds
                if let d = self.player?.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.playing = false
                self?.seek(0, play: false)
            }
        }
        Task {
            if let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite { duration = d }
        }
    }

    func toggle() {
        guard let player else { return }
        if playing { player.pause() } else { player.play(); started = true }
        playing.toggle()
    }

    func seek(_ seconds: Double, play: Bool) {
        guard let player else { return }
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play, !playing { player.play(); playing = true; started = true }
    }

    func skip(_ by: Double) { seek(min(max(0, time + by), duration), play: playing) }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
        player = nil
        playing = false
    }
}

/// Play, the scrubber and the times, pinned under the transcript.
struct PlayerBar: View {
    let player: AudioPlayer
    @State private var scrub: Double?

    var body: some View {
        HStack(spacing: 14) {
            Button { player.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back 15 seconds")

            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(player.playing ? "Pause" : "Play")

            Button { player.skip(15) } label: {
                Image(systemName: "goforward.15").font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Forward 15 seconds")

            Text(Format.clock(scrub ?? player.time))
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
            Slider(value: Binding(get: { scrub ?? player.time }, set: { scrub = $0 }),
                   in: 0...max(player.duration, 0.1)) { editing in
                if !editing, let s = scrub {
                    player.seek(s, play: player.playing)
                    scrub = nil
                }
            }
            .controlSize(.small)
            Text(Format.clock(player.duration))
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}
