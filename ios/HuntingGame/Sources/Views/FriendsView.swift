import SwiftUI

struct FriendsView: View {
    @StateObject private var viewModel = FriendsViewModel()
    @EnvironmentObject var presence: PresenceService
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = false

    /// When set, this sheet was opened from a lobby the user is currently hosting/in —
    /// friends get an INVITE button that sends them a lobby invite for this session.
    /// It doubles as "am I a sheet?": as a tab (the other way this screen is used) there's
    /// nothing to dismiss, so the Done button would be inert.
    var inviteSessionCode: String? = nil

    /// As a tab, LobbyView hands down the same crossfading tint every other tab is using
    /// so all four stay in step mid-swipe — see the comment on its `SwipeablePager` for
    /// why each page paints its own backdrop instead of sharing one. Nil in the
    /// standalone-sheet usage, which isn't part of that crossfade and just uses its own
    /// fixed accent.
    var backdropAccent: Color? = nil

    /// True in the standalone-sheet usage (opened from a lobby to invite friends), where
    /// there's no pager, no crossfade, and a solid background of its own underneath.
    private var isSheet: Bool { inviteSessionCode != nil }

    var body: some View {
        // Deliberately no `.navigationTitle` on this NavigationStack's root — see `header`
        // below, which stands in for one.
        NavigationStack {
            ZStack {
                RadarSweepBackdrop(accent: backdropAccent ?? ADATheme.hunterRed)
                    .edgesIgnoringSafeArea(.all)

                ScrollView {
                    VStack(spacing: 16) {
                        header

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
            }
            // The sweep itself is translucent, so it needs a dark ground of its own rather
            // than relying on whatever the enclosing NavigationStack happens to fill with.
            .obsidianBackdrop()
            .sheet(isPresented: $showScanner) {
                AddFriendSheet(mode: .scan) {
                    Task { await viewModel.loadAll() }
                }
            }
            .task { await viewModel.loadAll() }
        }
        .preferredColorScheme(.dark)
    }

    /// Stands in for a real navigation bar (see the `body` comment for why) — QR scan and,
    /// only in the invite-sheet usage, a Done button, with the title kept visually centered
    /// by reserving the same width on the trailing side even when Done isn't shown.
    private var header: some View {
        HStack {
            Button {
                showScanner = true
            } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(ADATheme.spatialCyan)

            Spacer()

            Text("Friends")
                .font(ADATheme.displayFont(size: 20))
                .foregroundColor(.white)

            Spacer()

            if inviteSessionCode != nil {
                Button("Done") { dismiss() }
                    .foregroundColor(ADATheme.spatialCyan)
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal)
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
                        // Only the identity half is the link, so the INVITE button beside
                        // it stays independently tappable instead of being swallowed by
                        // the row-wide navigation gesture.
                        NavigationLink {
                            PublicProfileView(userId: friend.id, displayName: friend.tagLabel)
                        } label: {
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
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.25))
                            }
                        }
                        .buttonStyle(.plain)

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
