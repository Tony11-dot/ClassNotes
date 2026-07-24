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
    @State private var showForgot = false
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
        .sheet(isPresented: $showForgot) { ForgotPasswordSheet(prefill: identifier) }
    }

    private var card: some View {
        VStack(spacing: 18) {
            BrandLockup(markSize: 60, fontSize: 30)
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

            HStack {
                Spacer()
                Button("Forgot password?") { showForgot = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent.color)
            }

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

/// "Forgot password?" — sends a reset link through ClassMate's backend
/// (`POST /auth/forgot-password`), same as the ClassMate app.
struct ForgotPasswordSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let prefill: String
    @State private var identifier: String
    @State private var busy = false
    @State private var sent = false

    init(prefill: String) {
        self.prefill = prefill
        self._identifier = State(initialValue: prefill)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground(seed: 9, opacity: 0.6)
                VStack(spacing: 18) {
                    if sent {
                        VStack(spacing: 10) {
                            Image(systemName: "envelope.badge")
                                .font(.system(size: 40))
                                .foregroundStyle(theme.accent.color)
                            Text("Check your email")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(theme.ink.color)
                            Text("If an account matches, we've sent a reset link. The link expires soon for your security.")
                                .font(.subheadline)
                                .foregroundStyle(theme.inkSecondary.color)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 24)
                    } else {
                        VStack(spacing: 6) {
                            Text("Reset your password")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(theme.ink.color)
                            Text("Enter your email or username and we'll send a reset link.")
                                .font(.subheadline)
                                .foregroundStyle(theme.inkSecondary.color)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 12)

                        TextField("Email or username", text: $identifier)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .padding(.horizontal, 14).padding(.vertical, 13)
                            .background(
                                theme.surfaceRaised.color,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )

                        Button {
                            busy = true
                            Task {
                                _ = await services.auth.requestPasswordReset(identifier: identifier)
                                busy = false
                                sent = true
                            }
                        } label: {
                            Group {
                                if busy { ProgressView() } else { Text("Email me a reset link").font(.headline) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(busy || identifier.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Forgot password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}
