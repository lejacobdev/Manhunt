import SwiftUI

struct AuthView: View {
    @StateObject private var viewModel = AuthViewModel()
    @State private var isRegisterMode = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("HUNTING GAME")
                    .font(.system(size: 32, weight: .black, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.top, 60)

                Text("Real-world GPS manhunt")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.gray)

                Picker("Mode", selection: $isRegisterMode) {
                    Text("Register").tag(true)
                    Text("Login").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 20)

                VStack(spacing: 12) {
                    TextField("Username", text: $viewModel.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding()
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)

                    if !isRegisterMode {
                        TextField("Tag (e.g. 4921)", text: $viewModel.userTag)
                            .keyboardType(.numberPad)
                            .padding()
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                    }

                    SecureField("Password", text: $viewModel.password)
                        .padding()
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                }
                .padding(.horizontal)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                Button(action: submit) {
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(isRegisterMode ? "CREATE ACCOUNT" : "LOG IN")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .background(Color.green.opacity(0.85))
                .foregroundColor(.black)
                .cornerRadius(10)
                .padding(.horizontal)
                .disabled(viewModel.isLoading)

                Spacer()
            }
            .background(Color.black.edgesIgnoringSafeArea(.all))
        }
    }

    private func submit() {
        Task {
            if isRegisterMode {
                await viewModel.register()
            } else {
                await viewModel.login()
            }
        }
    }
}

#Preview {
    AuthView()
}
