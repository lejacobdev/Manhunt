import SwiftUI

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
    /// Returns an error message, or nil on success.
    let onSubmit: (ReportCategory, String?) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var selected: ReportCategory?
    @State private var detail = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false

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
                    .font(ADATheme.uiFont(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 6) {
                    ForEach(ReportCategory.allCases) { category in
                        categoryRow(category)
                    }
                }

                if selected?.requiresDetail == true {
                    ADATextField(placeholder: "Describe what happened", text: $detail)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if selected != nil {
                    ADATextField(placeholder: "Add detail (optional)", text: $detail)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(ADATheme.hunterRed)
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
                    .font(ADATheme.uiFont(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
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

    private func categoryRow(_ category: ReportCategory) -> some View {
        let isSelected = selected == category
        return Button {
            selected = category
            errorMessage = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: category.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? ADATheme.hunterRed : .white.opacity(0.45))
                    .frame(width: 22)
                Text(category.label)
                    .font(ADATheme.uiFont(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(isSelected ? 1 : 0.75))
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? ADATheme.hunterRed : .white.opacity(0.25))
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
                .font(.system(size: 42, weight: .semibold))
                .foregroundColor(ADATheme.runnerGreen)
                .shadow(color: ADATheme.runnerGreen.opacity(0.5), radius: 14)

            Text("REPORT SENT")
                .font(ADATheme.displayFont(size: 20))
                .foregroundColor(.white)

            Text("Thanks — we review every report. You won't hear back individually, but action is taken on accounts that break the rules.")
                .font(ADATheme.uiFont(size: 13, weight: .medium))
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
        errorMessage = await onSubmit(selected, trimmed.isEmpty ? nil : trimmed)
        if errorMessage == nil {
            withAnimation(ADATheme.controlSpring) { didSubmit = true }
            HapticsEngine.shared.lightTap()
        }
    }
}
