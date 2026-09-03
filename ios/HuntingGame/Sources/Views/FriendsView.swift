import SwiftUI

struct FriendsView: View {
    @StateObject private var viewModel = FriendsViewModel()
    @EnvironmentObject var presence: PresenceService
    @Environment(\.dismiss) private var dismiss

    /// When set, this sheet was opened from a lobby the user is currently hosting/in —
    /// friends get an INVITE button that sends them a lobby invite for this session.
    var inviteSessionCode: String?

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
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(ADATheme.telemetryFont(size: 12))
                            .foregroundColor(ADATheme.hunterRed)
                            .padding(.horizontal)
                    }

                    if !viewModel.incomingRequests.isEmpty {
                        requestsSection
                    }

                    friendsSection

                    Spacer(minLength: 20)
                }
                .padding(.top)
                .adaptiveContentWidth()
                .animation(ADATheme.ambientSpring, value: viewModel.lastActionMessage)
                .animation(ADATheme.controlSpring, value: viewModel.incomingRequests.map(\.id))
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
            .task { await viewModel.loadAll() }
        }
        .preferredColorScheme(.dark)
    }

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FRIEND REQUESTS")
                .font(ADATheme.telemetryFont(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 4)

            ForEach(viewModel.incomingRequests) { request in
                HStack(spacing: 10) {
                    Circle()
                        .fill(ADATheme.tacticalAmber.opacity(0.25))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Text(request.otherUser.username.prefix(1).uppercased())
                                .font(ADATheme.telemetryFont(size: 11))
                                .foregroundColor(ADATheme.tacticalAmber)
                        )
                    Text(request.otherUser.tagLabel)
                        .font(ADATheme.uiFont(size: 13))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        Task { await viewModel.decline(request) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(ADATheme.hunterRed)
                    }
                    Button {
                        Task { await viewModel.accept(request) }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(ADATheme.runnerGreen)
                    }
                }
                .font(.system(size: 22))
                .padding(12)
                .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: ADATheme.tacticalAmber)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal)
    }

    private var friendsSection: some View {
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
                            .fill(isOnline(friend) ? ADATheme.runnerGreen : .white.opacity(0.2))
                            .frame(width: 8, height: 8)
                            .shadow(color: isOnline(friend) ? ADATheme.runnerGreen : .clear, radius: 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(friend.tagLabel)
                                .font(ADATheme.uiFont(size: 13))
                                .foregroundColor(.white)
                            Text(isOnline(friend) ? "ONLINE" : "OFFLINE")
                                .font(ADATheme.telemetryFont(size: 9))
                                .foregroundColor(isOnline(friend) ? ADATheme.runnerGreen : .white.opacity(0.3))
                        }
                        Spacer()
                        if let sessionCode = inviteSessionCode, isOnline(friend) {
                            Button("INVITE") {
                                Task { await viewModel.invite(friend, toSessionCode: sessionCode) }
                            }
                            .buttonStyle(GlassButtonStyle(tint: ADATheme.spatialCyan))
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .glassCard(cornerRadius: ADATheme.controlCornerRadius)
                }
            }
        }
        .padding(.horizontal)
    }

    private func isOnline(_ friend: AppUser) -> Bool {
        presence.onlineFriendIds.contains(friend.id) || friend.isOnline == true
    }
}
