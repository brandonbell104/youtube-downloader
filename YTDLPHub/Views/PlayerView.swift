import AVKit
import SwiftUI

/// Full-screen playback for a library item, straight off the local file.
struct PlayerView: View {
    let item: LibraryItem

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("This file is no longer on the device.")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .statusBarHidden()
        .onAppear(perform: start)
        .onDisappear {
            player?.pause()
            player = nil
            // Hand audio back to whatever was playing before.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func start() {
        guard item.exists else { return }
        // Without this, playback is silenced by the ring/silent switch.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let player = AVPlayer(url: item.fileURL)
        player.allowsExternalPlayback = true
        self.player = player
        player.play()
    }
}
