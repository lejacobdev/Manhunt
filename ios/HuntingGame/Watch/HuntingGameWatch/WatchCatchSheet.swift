import SwiftUI

struct WatchCatchSheet: View {
    let target: WatchRunnerBlip
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("CATCH \(target.username.uppercased())")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)

                TextField("Arrest code", text: $code)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)

                Button("CONFIRM") {
                    onConfirm(code)
                }
                .tint(TacticalPalette.hunterRed)
                .disabled(code.count < 4)

                Button("Cancel") { dismiss() }
                    .font(.footnote)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 6)
        }
    }
}
