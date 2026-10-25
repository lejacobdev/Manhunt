import SwiftUI
import PhotosUI

/// What a report is about. Raw values are the wire contract with the backend's
/// `ReportCategory` enum — changing one means changing both and migrating the column.
enum ReportCategory: String, CaseIterable, Identifiable {
    case cheating = "CHEATING"
    case inappropriateUsername = "INAPPROPRIATE_USERNAME"
    case harassment = "HARASSMENT"
    case threats = "THREATS"
    case sexualContent = "SEXUAL_CONTENT"
    case impersonation = "IMPERSONATION"
    case unsafePlay = "UNSAFE_PLAY"
    case other = "OTHER"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cheating: return "Cheating or fake GPS"
        case .inappropriateUsername: return "Inappropriate username"
        case .harassment: return "Harassment or bullying"
        case .threats: return "Threats or violence"
        case .sexualContent: return "Sexual or explicit content"
        case .impersonation: return "Pretending to be someone else"
        case .unsafePlay: return "Unsafe or dangerous play"
        case .other: return "Something else"
        }
    }

    var icon: String {
        switch self {
        case .cheating: return "location.slash.fill"
        case .inappropriateUsername: return "textformat.abc"
        case .harassment: return "exclamationmark.bubble.fill"
        case .threats: return "exclamationmark.triangle.fill"
        case .sexualContent: return "eye.slash.fill"
        case .impersonation: return "person.fill.questionmark"
        case .unsafePlay: return "car.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    /// OTHER carries no meaning on its own, so it's the one case where detail is required.
    var requiresDetail: Bool { self == .other }
}

/// Pick-a-reason reporting. Categories rather than a prose box: a category can be counted
/// and triaged across accounts ("four cheating reports this week"), where free text can
/// only be read one at a time — and it's far quicker to file, which matters for something
/// people do mid-match.
struct ReportSheet: View {
    let displayName: String
    /// Returns an error message, or nil on success. The data are JPEG screenshots, already shrunk.
    let onSubmit: (ReportCategory, String?, [Data]) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var selected: ReportCategory?
    @State private var detail = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false
    @State private var pickedItems: [PhotosPickerItem] = []
    /// The attached screenshots, ready to send: downscaled JPEGs with their previews.
    @State private var screenshots: [(preview: UIImage, jpeg: Data)] = []
    @State private var isLoadingScreenshots = false

    static let maxScreenshots = 3

    private var canSubmit: Bool {
        guard let selected, !isSubmitting else { return false }
        return !selected.requiresDetail || !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RadarSweepBackdrop(accent: ADATheme.hunterRed)
                    .edgesIgnoringSafeArea(.all)

                if didSubmit {
                    submittedState
                } else {
                    form
                }
            }
            .obsidianBackdrop()
            .navigationTitle(didSubmit ? "" : "Report \(displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(didSubmit ? "Done" : "Cancel") { dismiss() }
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("What's going on?")
                    .tacticalFont(.ui, size: 13, weight: .medium)
                    .tacticalText(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 6) {
                    ForEach(ReportCategory.allCases) { category in
                        categoryRow(category)
                    }
                }

                if selected?.requiresDetail == true {
                    ADATextField(placeholder: "Describe what happened", text: $detail)
                        .tacticalTransition(.opacity.combined(with: .move(edge: .top)))
                } else if selected != nil {
                    ADATextField(placeholder: "Add detail (optional)", text: $detail)
                        .tacticalTransition(.opacity.combined(with: .move(edge: .top)))
                }

                if selected != nil {
                    screenshotPicker
                        .tacticalTransition(.opacity.combined(with: .move(edge: .top)))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .tacticalFont(.telemetry, size: 12)
                        .foregroundColor(ADATheme.hunterRedText)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView().tint(.black)
                    } else {
                        HStack { Image(systemName: "flag.fill"); Text("SEND REPORT") }
                    }
                }
                .buttonStyle(GlowButtonStyle(tint: ADATheme.hunterRed, isLoading: isSubmitting))
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.4)
                .padding(.top, 4)

                Text("Reports go to the Hunting Game team. If you also want them out of your friends list and unable to contact you, block them from their profile.")
                    .tacticalFont(.ui, size: 11, weight: .medium)
                    .tacticalText(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .adaptiveContentWidth()
            .animation(ADATheme.controlSpring, value: selected)
            .animation(ADATheme.controlSpring, value: errorMessage)
        }
    }

    /// Up to three screenshots as evidence — a chat, a username, a fake location.
    private var screenshotPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SCREENSHOTS (OPTIONAL)")
                .tacticalFont(.telemetry, size: 10)
                .tacticalText(.secondary)
            HStack(spacing: 10) {
                ForEach(Array(screenshots.enumerated()), id: \.offset) { index, shot in
                    Image(uiImage: shot.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                screenshots.remove(at: index)
                                if index < pickedItems.count { pickedItems.remove(at: index) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Remove screenshot \(index + 1)")
                        }
                        .accessibilityLabel("Screenshot \(index + 1)")
                }
                if screenshots.count < Self.maxScreenshots {
                    PhotosPicker(selection: $pickedItems, maxSelectionCount: Self.maxScreenshots, matching: .images) {
                        VStack(spacing: 6) {
                            if isLoadingScreenshots {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "photo.badge.plus")
                                    .tacticalFont(.symbol, size: 20, weight: .semibold)
                                Text("ADD")
                                    .tacticalFont(.telemetry, size: 9)
                            }
                        }
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 72, height: 96)
                        .glassCard(cornerRadius: 10)
                    }
                    .accessibilityLabel("Add screenshots")
                }
                Spacer(minLength: 0)
            }
            Text("Only the Hunting Game team sees these.")
                .tacticalFont(.ui, size: 11, weight: .medium)
                .tacticalText(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: pickedItems) { items in
            Task { await loadScreenshots(items) }
        }
    }

    private func loadScreenshots(_ items: [PhotosPickerItem]) async {
        isLoadingScreenshots = true
        defer { isLoadingScreenshots = false }
        var loaded: [(UIImage, Data)] = []
        for item in items.prefix(Self.maxScreenshots) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let prepared = Self.prepare(image) else { continue }
            loaded.append(prepared)
        }
        screenshots = loaded.map { (preview: $0.0, jpeg: $0.1) }
    }

    /// Shrinks a screenshot to at most 1600 px on its long side and re-encodes it as JPEG. That
    /// keeps it readable, well under the server's 2 MB limit, and drops the photo's metadata
    /// (location included), since only the pixels are redrawn.
    static func prepare(_ image: UIImage) -> (UIImage, Data)? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1600 / max(longest, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        var quality: CGFloat = 0.75
        var data = resized.jpegData(compressionQuality: quality)
        while let current = data, current.count > 1_800_000, quality > 0.3 {
            quality -= 0.15
            data = resized.jpegData(compressionQuality: quality)
        }
        guard let data else { return nil }
        return (resized, data)
    }

    private func categoryRow(_ category: ReportCategory) -> some View {
        let isSelected = selected == category
        return Button {
            selected = category
            errorMessage = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: category.icon)
                    .tacticalFont(.symbol, size: 14, weight: .semibold)
                    .foregroundColor(isSelected ? ADATheme.hunterRed : .white.opacity(0.64))
                    .frame(width: 22)
                Text(category.label)
                    .tacticalFont(.ui, size: 14, weight: .medium)
                    .foregroundColor(.white.opacity(isSelected ? 1 : 0.75))
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .tacticalFont(.symbol, size: 15, weight: .regular)
                    .foregroundColor(isSelected ? ADATheme.hunterRed : .white.opacity(0.54))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .glassCard(
                cornerRadius: ADATheme.controlCornerRadius,
                tint: isSelected ? ADATheme.hunterRed : .white
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var submittedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .tacticalFont(.symbol, size: 42, weight: .semibold)
                .foregroundColor(ADATheme.runnerGreen)
                .shadow(color: ADATheme.runnerGreen.opacity(0.5), radius: 14)

            Text("REPORT SENT")
                .tacticalFont(.display, size: 20)
                .foregroundColor(.white)

            Text("Thanks — we review every report. You won't hear back individually, but action is taken on accounts that break the rules.")
                .tacticalFont(.ui, size: 13, weight: .medium)
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .padding(.horizontal, 20)
        .adaptiveContentWidth()
    }

    private func submit() async {
        guard let selected, canSubmit else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = await onSubmit(selected, trimmed.isEmpty ? nil : trimmed, screenshots.map(\.jpeg))
        if errorMessage == nil {
            withAnimation(ADATheme.controlSpring) { didSubmit = true }
            HapticsEngine.shared.lightTap()
        }
    }
}
