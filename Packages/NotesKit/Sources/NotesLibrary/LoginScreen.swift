import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// Sign-in against ClassMate's real accounts — mirrors ClassMate's login card:
/// wordmark, "Welcome back", email-or-username + password, primary "Sign in".
public struct LoginScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme

    @State private var identifier = ""
    @State private var password = ""
    @State private var busy = false
    @State private var showRegister = false
    @FocusState private var focus: Field?

    private enum Field { case identifier, password }

    public init() {}

    public var body: some View {
        ZStack {
            AmbientBackground(seed: 5)
            ScrollView {
                card
                    .frame(maxWidth: 400)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showRegister) { RegisterSheet() }
    }

    private var card: some View {
        VStack(spacing: 18) {
            BrandWordmark(height: 50)
                .padding(.bottom, 4)
            VStack(spacing: 4) {
                Text("Welcome back")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.ink.color)
                Text("Sign in to your ClassMate account.")
                    .font(.subheadline)
                    .foregroundStyle(theme.inkSecondary.color)
            }

            field(
                text: $identifier,
                placeholder: "Email or username",
                systemImage: "at",
                field: .identifier
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .submitLabel(.next)
            .onSubmit { focus = .password }

            field(
                text: $password,
                placeholder: "Password",
                systemImage: "lock",
                field: .password,
                secure: true
            )
            .submitLabel(.go)
            .onSubmit(signIn)

            if let error = services.auth.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: signIn) {
                Group {
                    if busy {
                        ProgressView().tint(theme.contrastingInk(on: theme.accent).color)
                    } else {
                        Text("Sign in").font(.headline)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.glassProminent)
            .disabled(busy)

            Button("Create an account") { showRegister = true }
                .font(.subheadline)
                .foregroundStyle(theme.accent.color)
        }
        .padding(28)
        .background(
            theme.surface.color,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(theme.separator.color.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.08), radius: 30, y: 12)
    }

    @ViewBuilder
    private func field(
        text: Binding<String>,
        placeholder: String,
        systemImage: String,
        field: Field,
        secure: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(theme.inkSecondary.color)
                .frame(width: 20)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .foregroundStyle(theme.ink.color)
            .focused($focus, equals: field)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            theme.surfaceRaised.color.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    focus == field ? theme.accent.color : theme.separator.color.opacity(0.6),
                    lineWidth: focus == field ? 1.4 : 0.5
                )
        )
    }

    private func signIn() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            _ = await services.auth.signIn(identifier: identifier, password: password)
        }
    }
}

/// Minimal registration against `POST /auth/register`.
struct RegisterSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Full name", text: $name)
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                if let error = services.auth.lastError {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Create account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        busy = true
                        Task {
                            defer { busy = false }
                            if await services.auth.register(email: email, name: name, password: password) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(busy || name.isEmpty || email.isEmpty || password.count < 3)
                }
            }
        }
    }
}
