import SwiftUI

struct FriendsView: View {
    @StateObject private var viewModel = FriendsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ADATextField(placeholder: "Search username or username#tag", text: $viewModel.searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal)
                        .onChange(of: viewModel.searchQuery) { _ in
                            Task { await viewModel.search() }
                        }

                    if !viewModel.searchResults.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(viewModel.searchResults) { user in
                                HStack {
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(ADATheme.spatialCyan.opacity(0.25))
                                            .frame(width: 28, height: 28)
                                            .overlay(
                                                Text(user.username.prefix(1).uppercased())
                                                    .font(ADATheme.telemetryFont(size: 11))
                                                    .foregroundColor(ADATheme.spatialCyan)
                                            )
                                        Text(user.tagLabel)
                                            .font(ADATheme.uiFont(size: 13))
                                            .foregroundColor(.white)
                                    }
                                    Spacer()
                                    Button("ADD") { Task { await viewModel.sendRequest(to: user) } }
                                        .buttonStyle(GlassButtonStyle(tint: ADATheme.runnerGreen))
                                }
                                .padding(12)
                                .glassCard(cornerRadius: ADATheme.controlCornerRadius)
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal)
                        .animation(ADATheme.controlSpring, value: viewModel.searchResults.map(\.id))
                    }

                    if let message = viewModel.lastActionMessage {
                        StatusBadge(icon: "checkmark.circle.fill", text: message.uppercased(), tint: ADATheme.runnerGreen)
                            .transition(.scale.combined(with: .opacity))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("YOUR FRIENDS")
                            .font(ADATheme.telemetryFont(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.leading, 4)

                        if viewModel.friends.isEmpty {
                            Text("No friends yet — search above to send a request.")
                                .font(ADATheme.uiFont(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.35))
                        } else {
                            ForEach(viewModel.friends) { friend in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(ADATheme.runnerGreen.opacity(0.2))
                                        .frame(width: 8, height: 8)
                                    Text(friend.tagLabel)
                                        .font(ADATheme.uiFont(size: 13))
                                        .foregroundColor(.white)
                                    Spacer()
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                                .glassCard(cornerRadius: ADATheme.controlCornerRadius)
                            }
                        }
                    }
                    .padding(.horizontal)

                    Spacer(minLength: 20)
                }
                .padding(.top)
                .animation(ADATheme.ambientSpring, value: viewModel.lastActionMessage)
            }
            .obsidianBackdrop()
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(ADATheme.spatialCyan)
                }
            }
            .task { await viewModel.loadFriends() }
        }
        .preferredColorScheme(.dark)
    }
}
