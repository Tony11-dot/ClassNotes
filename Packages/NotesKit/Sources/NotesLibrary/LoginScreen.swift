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
            GeometryReader { geo in
                ScrollView {
                    // Card centered vertically: a min-height container equal to
                    // the viewport keeps the card in the middle (like ClassMate's
                    // Center + SingleChildScrollView), still scrollable when the
                    // keyboard shrinks the space.
                    card
                        .frame(maxWidth: 400)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        .padding(.horizontal, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .fullScreenCover(isPresented: $showForgot) {
            ForgotPasswordScreen(prefill: identifier)
        }
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

/// "Forgot password?" — a full screen (NOT a bottom sheet), mirroring
/// ClassMate's `ForgotPasswordScreen`: a top-aligned column with an Email/SMS
/// channel picker, an identifier field, a send button, the server's message,
/// and the "link expires in 1 hour" note. Sends through ClassMate's backend
/// (`POST /auth/forgot-password`, channel email|sms), same accounts.
struct ForgotPasswordScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    enum ResetMode: String, CaseIterable { case email, sms }

    let prefill: String
    @State private var identifier: String
    @State private var mode: ResetMode = .email
    @State private var busy = false
    @State private var message: String?
    @State private var success = false

    init(prefill: String) {
        self.prefill = prefill
        self._identifier = State(initialValue: prefill)
    }

    private var headerCopy: String {
        mode == .email
            ? "Enter your email or username and we'll email you a reset link."
            : "Enter your email or username and we'll text a reset link to the phone on your account."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Forgot password")
                        .font(.title.weight(.heavy))
                        .foregroundStyle(theme.ink.color)
                    Text(headerCopy)
                        .font(.body)
                        .foregroundStyle(theme.inkSecondary.color)
                        .lineSpacing(3)
                        .padding(.top, 8)

                    // Email / SMS channel picker.
                    Picker("Channel", selection: $mode) {
                        Label("Email", systemImage: "envelope").tag(ResetMode.email)
                        Label("Text", systemImage: "message").tag(ResetMode.sms)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, _ in message = nil }
                    .padding(.top, 24)

                    HStack(spacing: 10) {
                        Image(systemName: "at").foregroundStyle(theme.inkSecondary.color).frame(width: 20)
                        TextField("Email or username", text: $identifier)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .foregroundStyle(theme.ink.color)
                            .submitLabel(.send)
                            .onSubmit(submit)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 14)
                    .background(theme.surfaceRaised.color.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.separator.color.opacity(0.6), lineWidth: 0.5))
                    .padding(.top, 20)

                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if busy {
                                BrandLoader(size: 18, tint: theme.contrastingInk(on: theme.accent).color)
                            } else {
                                Image(systemName: mode == .email ? "paperplane.fill" : "message.fill")
                                Text(mode == .email ? "Email me a reset link" : "Text me a reset link")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(busy || identifier.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.top, 20)

                    if let message {
                        Label {
                            Text(message).foregroundStyle(theme.ink.color)
                        } icon: {
                            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(success ? Color.green : Color.orange)
                        }
                        .font(.subheadline)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((success ? Color.green : Color.orange).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, 18)
                    }

                    Text("The link expires in 1 hour and can only be used once.")
                        .font(.footnote)
                        .foregroundStyle(theme.inkSecondary.color)
                        .padding(.top, 24)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(theme.surface.color.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back")
                }
            }
        }
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        Task {
            let result = await services.auth.requestPasswordReset(
                identifier: identifier, channel: mode.rawValue
            )
            busy = false
            success = result.sent
            message = result.message ?? (result.sent
                ? "If an account matches, a reset link is on its way."
                : "We couldn't send a reset link. Check the details and try again.")
        }
    }
}
