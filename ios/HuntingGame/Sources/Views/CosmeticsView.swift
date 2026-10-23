import SwiftUI
import StoreKit

/// Customize: map styles, radar skins, markers, banners and badges. Every item is looks only.
/// Some are free, some unlock by playing, some come in packs; Supporter includes every pack.
struct CosmeticsView: View {
    @StateObject private var store = CosmeticsStore.shared
    /// Simulator screenshot scenarios: show the sample snapshot instead of loading.
    var isPreview = false

    private let sections: [(id: String, title: String, note: String)] = [
        ("mapStyle", "MAP STYLE", "Only you see it."),
        ("radarSkin", "RADAR SKIN", "Only you see it."),
        ("marker", "MAP MARKER", "Your teammates see it on their map."),
        ("banner", "PROFILE BANNER", "Everyone sees it on your profile."),
        ("badge", "BADGE", "Everyone sees it next to your name."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Looks only — nothing here changes how a match plays.")
                    .tacticalFont(.ui, size: 13, weight: .medium)
                    .tacticalText(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let snapshot = store.snapshot {
                    supporterCard(snapshot)
                    ForEach(sections, id: \.id) { section in
                        categorySection(section, snapshot: snapshot)
                    }
                    packs(snapshot)
                    Button("Restore purchases") { Task { await store.restore() } }
                        .buttonStyle(TacticalGhostButtonStyle(tint: .white))
                        .disabled(store.isWorking)
                } else {
                    ProgressView().tint(.white).padding(.top, 60)
                }
            }
            .padding(.vertical, 16)
            .adaptiveContentWidth()
        }
        .navigationTitle("Customize")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { if !isPreview { await store.refresh() } }
        .alert("Customize", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.message ?? "")
        }
    }

    // MARK: - Sections

    private func supporterCard(_ snapshot: CosmeticsSnapshot) -> some View {
        let supporter = snapshot.products.first { $0.productId.hasSuffix(".supporter") }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "heart.fill")
                    .tacticalFont(.symbol, size: 18, weight: .bold)
                    .foregroundColor(Color(hex: "#FFD66B"))
                Text("SUPPORTER")
                    .tacticalFont(.telemetry, size: 13)
                    .foregroundColor(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if supporter?.owned == true {
                    Text("THANK YOU")
                        .tacticalFont(.telemetry, size: 10)
                        .foregroundColor(Color(hex: "#FFD66B"))
                }
            }
            Text(supporter?.description ?? "")
                .tacticalFont(.ui, size: 13, weight: .medium)
                .tacticalText(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let supporter, !supporter.owned {
                Button {
                    Task { await store.buy(supporter.productId) }
                } label: {
                    Text(store.products[supporter.productId].map { "BECOME A SUPPORTER · \($0.displayPrice)" } ?? "BECOME A SUPPORTER")
                }
                .buttonStyle(GlowButtonStyle(tint: Color(hex: "#FFD66B")))
                .disabled(store.isWorking)
            }
        }
        .padding(18)
        .glassCard(tint: Color(hex: "#FFD66B"))
        .padding(.horizontal)
    }

    private func categorySection(_ section: (id: String, title: String, note: String), snapshot: CosmeticsSnapshot) -> some View {
        let items = snapshot.items.filter { $0.category == section.id }
        let equipped = snapshot.equipped[section.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.title)
                    .tacticalFont(.telemetry, size: 11)
                    .tacticalText(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(section.note)
                    .tacticalFont(.ui, size: 11, weight: .medium)
                    .tacticalText(.tertiary)
            }
            .padding(.horizontal, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(items) { item in
                    itemTile(item, isEquipped: item.id == equipped)
                }
            }
        }
        .padding(.horizontal)
    }

    private func itemTile(_ item: CosmeticsSnapshot.Item, isEquipped: Bool) -> some View {
        Button {
            if item.owned { Task { await store.equip(item) } }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    preview(item)
                    Spacer()
                    if isEquipped {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(ADATheme.runnerGreen)
                            .accessibilityHidden(true)
                    } else if !item.owned {
                        Image(systemName: "lock.fill")
                            .tacticalText(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                Text(item.name)
                    .tacticalFont(.ui, size: 14, weight: .bold)
                    .foregroundColor(.white)
                Text(statusLine(item, isEquipped: isEquipped))
                    .tacticalFont(.telemetry, size: 9)
                    .foregroundColor(isEquipped ? ADATheme.runnerGreen : item.owned ? ADATheme.spatialCyan : .white.opacity(0.54))
                    .fixedSize(horizontal: false, vertical: true)
                if !item.owned, let progress = item.progress, let goal = item.goal, goal > 0 {
                    ProgressView(value: Double(progress), total: Double(goal))
                        .tint(ADATheme.spatialCyan)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: isEquipped ? ADATheme.runnerGreen : .clear)
            .opacity(item.owned ? 1 : 0.8)
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.97))
        .disabled(!item.owned || isEquipped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.description)")
        .accessibilityValue(statusLine(item, isEquipped: isEquipped))
        .accessibilityHint(item.owned && !isEquipped ? "Double-tap to equip." : "")
        .accessibilityAddTraits(isEquipped ? .isSelected : [])
    }

    @ViewBuilder
    private func preview(_ item: CosmeticsSnapshot.Item) -> some View {
        switch item.category {
        case "banner":
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: CosmeticStyle.bannerColors(item.id), startPoint: .leading, endPoint: .trailing))
                .frame(width: 44, height: 22)
        case "radarSkin":
            Circle()
                .stroke(CosmeticStyle.radarAccent(item.id) ?? ADATheme.runnerGreen, lineWidth: 3)
                .frame(width: 26, height: 26)
        case "badge":
            if CosmeticStyle.badge(item.id) != nil { CosmeticBadgeView(id: item.id) } else {
                Image(systemName: "circle.slash").tacticalText(.tertiary)
            }
        default:
            Image(systemName: CosmeticStyle.previewIcon(item.category, id: item.id))
                .tacticalFont(.symbol, size: 18, weight: .bold)
                .foregroundColor(ADATheme.spatialCyan)
        }
    }

    private func statusLine(_ item: CosmeticsSnapshot.Item, isEquipped: Bool) -> String {
        if isEquipped { return "EQUIPPED" }
        if item.owned { return "TAP TO EQUIP" }
        switch item.unlock {
        case "play":
            return "\(item.requirement?.uppercased() ?? "PLAY TO UNLOCK") · \(item.progress ?? 0)/\(item.goal ?? 0)"
        case "supporter":
            return "SUPPORTER"
        default:
            let pack = store.snapshot?.products.first { $0.productId == item.productId }
            return "IN THE \(pack?.name.uppercased() ?? "SHOP")"
        }
    }

    private func packs(_ snapshot: CosmeticsSnapshot) -> some View {
        let packs = snapshot.products.filter { !$0.productId.hasSuffix(".supporter") }
        return VStack(alignment: .leading, spacing: 8) {
            Text("PACKS")
                .tacticalFont(.telemetry, size: 11)
                .tacticalText(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(packs) { pack in
                    if pack.id != packs.first?.id {
                        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                    }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name)
                                .tacticalFont(.ui, size: 14, weight: .bold)
                                .foregroundColor(.white)
                            Text(pack.description)
                                .tacticalFont(.ui, size: 12, weight: .medium)
                                .tacticalText(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if pack.owned {
                            Text("OWNED")
                                .tacticalFont(.telemetry, size: 10)
                                .foregroundColor(ADATheme.runnerGreen)
                        } else {
                            Button(store.products[pack.productId]?.displayPrice ?? "BUY") {
                                Task { await store.buy(pack.productId) }
                            }
                            .buttonStyle(TacticalGhostButtonStyle(tint: ADATheme.spatialCyan))
                            .disabled(store.isWorking)
                            .accessibilityLabel("Buy \(pack.name)\(store.products[pack.productId].map { " for \($0.displayPrice)" } ?? "")")
                        }
                    }
                    .padding(14)
                }
            }
            .glassCard()
        }
        .padding(.horizontal)
    }
}
