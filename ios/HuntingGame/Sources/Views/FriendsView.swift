import SwiftUI

struct FriendsView: View {
    @StateObject private var viewModel = FriendsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("Search username or username#tag", text: $viewModel.searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .onChange(of: viewModel.searchQuery) { _ in
                        Task { await viewModel.search() }
                    }

                if !viewModel.searchResults.isEmpty {
                    List(viewModel.searchResults) { user in
                        HStack {
                            Text(user.tagLabel).font(.system(size: 13, design: .monospaced))
                            Spacer()
                            Button("Add") { Task { await viewModel.sendRequest(to: user) } }
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                        .listRowBackground(Color.black)
                    }
                    .listStyle(.plain)
                    .frame(height: 200)
                }

                if let message = viewModel.lastActionMessage {
                    Text(message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.green)
                }

                Divider().background(Color.gray)

                Text("YOUR FRIENDS")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)

                List(viewModel.friends) { friend in
                    Text(friend.tagLabel)
                        .font(.system(size: 13, design: .monospaced))
                        .listRowBackground(Color.black)
                }
                .listStyle(.plain)

                Spacer()
            }
            .padding(.top)
            .background(Color.black.edgesIgnoringSafeArea(.all))
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await viewModel.loadFriends() }
        }
    }
}
