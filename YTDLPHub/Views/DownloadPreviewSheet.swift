import SwiftUI

/// Confirmation step: shows what was found behind the link and lets the user
/// change quality before committing to the download.
struct DownloadPreviewSheet: View {
    let media: ResolvedMedia
    let link: String
    @Binding var quality: QualityPreference
    let onConfirm: (QualityPreference) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        RemoteThumbnail(url: media.metadata.thumbnailURL)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Text(media.metadata.title)
                            .font(.headline)

                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Quality") {
                    Picker("Quality", selection: $quality) {
                        ForEach(availableQualities) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    LabeledContent("Format", value: planDescription)
                    if let size = estimatedSize {
                        LabeledContent("Approximate size", value: size)
                    }
                } footer: {
                    if plan?.requiresMerge == true {
                        Text("YouTube stores anything above 720p as separate video and audio files. Both are downloaded and combined on your device.")
                    }
                }
            }
            .navigationTitle("Add download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { onConfirm(quality) }
                        .disabled(plan == nil)
                }
            }
        }
    }

    private var subtitle: String {
        [media.metadata.channel, media.metadata.formattedDuration]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Only offer resolutions this video actually has, so the picker never
    /// promises a 4K download of a 720p upload.
    private var availableQualities: [QualityPreference] {
        let tallest = media.streams.compactMap { $0.height }.max() ?? 0
        return QualityPreference.allCases.filter { option in
            guard let cap = option.maxHeight else { return true }
            // Keep the first cap at or above the source height so there is
            // always a "download it at full quality" entry.
            return cap <= tallest || QualityPreference.smallestCap(atLeast: tallest) == option
        }
    }

    private var plan: DownloadPlan? {
        StreamSelector.plan(for: media.streams, preference: quality)
    }

    private var planDescription: String {
        guard let plan else { return "Not available" }
        if plan.isAudioOnly { return "Audio · \(plan.outputExtension.uppercased())" }
        let label = StreamSelector.label(for: plan) ?? "Video"
        return plan.requiresMerge
            ? "\(label) · video + audio, merged"
            : "\(label) · single file"
    }

    private var estimatedSize: String? {
        plan?.totalBytes.flatMap { Formatters.bytes($0) }
    }
}

extension QualityPreference {
    /// The lowest capped preset that still covers `height`.
    static func smallestCap(atLeast height: Int) -> QualityPreference? {
        allCases
            .filter { ($0.maxHeight ?? 0) >= height && $0.maxHeight != nil }
            .min { ($0.maxHeight ?? 0) < ($1.maxHeight ?? 0) }
    }
}
