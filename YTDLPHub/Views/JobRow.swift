import SwiftUI

struct JobRow: View {
    @ObservedObject var job: DownloadJob
    @EnvironmentObject private var coordinator: DownloadCoordinator

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteThumbnail(url: job.record.metadata?.thumbnailURL)
                .frame(width: 72, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(job.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                if job.state == .downloading || job.state == .merging {
                    ProgressView(value: job.record.fractionComplete ?? 0)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        // A faded bar reads better than a stuck 0% when the
                        // server didn't send a content length.
                        .opacity(job.record.fractionComplete == nil ? 0.4 : 1)
                }

                HStack(spacing: 6) {
                    Image(systemName: job.state.symbolName)
                        .font(.caption2)
                        .foregroundStyle(tint)
                    Text(job.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            controls
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                coordinator.remove(job)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch job.state {
        case .failed, .cancelled:
            Button {
                coordinator.retry(job)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        default:
            Button {
                coordinator.cancel(job)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private var tint: Color {
        switch job.state {
        case .failed: return .red
        case .completed: return .green
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }
}

/// Async image with a neutral placeholder, sized by its container.
struct RemoteThumbnail: View {
    let url: URL?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        Image(systemName: "photo").foregroundStyle(.tertiary)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
            } else {
                Image(systemName: "film").foregroundStyle(.tertiary)
            }
        }
        .clipped()
    }
}
