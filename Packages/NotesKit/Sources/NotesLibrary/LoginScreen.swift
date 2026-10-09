import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// Signing in to ClassNotes.
///
/// The account is a ClassNotes account (`/classnotes/auth/login`) — the app's
/// own, created in `SignUpScreen`. It used to be a ClassMate school account,
/// which is why this screen used to ask for an "email or username": ClassMate
/// has both. ClassNotes has one identifier, the email, so that is all it asks.
///
/// An account is optional (D-001). As the first screen it offers "Continue
/// without an account"; opened from Settings (`asSheet`) it closes itself once
/// signed in.
public struct LoginScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private let asSheet: Bool

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var showForgot = false
    @State private var showSignUp = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    public init(asSheet: Bool = false) {
        self.asSheet = asSheet
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            AmbientBackground(seed: 5)
            GeometryReader { geo in
                ScrollView {
                    // Card centered vertically: a min-height container equal to
                    // the viewport keeps the card in the middle, still
                    // scrollable when the keyboard shrinks the space.
                    card
                        .frame(maxWidth: 400)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        .padding(.horizontal, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            if asSheet {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.dsHeadline)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .padding(16)
                .accessibilityLabel("Close")
            }
        }
        .onChange(of: services.auth.state) { _, state in
            if asSheet, state == .authenticated { dismiss() }
        }
        .fullScreenCover(isPresented: $showForgot) {
            ForgotPasswordScreen(prefill: email)
        }
        .fullScreenCover(isPresented: $showSignUp) { SignUpScreen() }
    }

    private var card: some View {
        VStack(spacing: 18) {
            BrandLockup(height: 54)
                .padding(.bottom, 4)
            VStack(spacing: 4) {
                Text(asSheet ? "Sign in" : "Welcome back")
                    .font(.dsTitle2.weight(.bold))
                    .foregroundStyle(theme.ink.color)
                Text(asSheet
                     ? "Sign in to sync your notebooks and use NOVA."
                     : "Sign in to your ClassNotes account.")
                    .font(.dsSubheadline)
                    .foregroundStyle(theme.inkSecondary.color)
                    .multilineTextAlignment(.center)
            }

            field(
                text: $email,
                placeholder: "Email",
                systemImage: "at",
                field: .email
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .submitLabel(.next)
            .onSubmit { focus = .password }

            field(
                text: $password,
                placeholder: "Password",
                systemImage: "lock",
                field: .password,
                secure: true
            )
            .textContentType(.password)
            .submitLabel(.go)
            .onSubmit(signIn)

            HStack {
                Spacer()
                Button("Forgot password?") { showForgot = true }
                    .font(.dsSubheadline.weight(.semibold))
                    .foregroundStyle(theme.accent.color)
            }

            if let error = services.auth.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.dsFootnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: signIn) {
                Group {
                    if busy {
                        // The brand's own loader, never the system spinner — the CN
                        // monogram drawing itself on is what ClassMate shows while
                        // it waits, everywhere it waits.
                        BrandLoader(size: 22, tint: theme.contrastingInk(on: theme.accent).color)
                    } else {
                        Text("Sign in").font(.dsHeadline)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.glassProminent)
            .disabled(busy)

            HStack(spacing: 4) {
                Text("New here?")
                    .foregroundStyle(theme.inkSecondary.color)
                Button("Create an account") { showSignUp = true }
                    .foregroundStyle(theme.accent.color)
                    .buttonStyle(.plain)
            }
            .font(.dsSubheadline)

            if !asSheet {
                VStack(spacing: 4) {
                    Button("Continue without an account") {
                        services.auth.continueWithoutAccount()
                    }
                    .font(.dsSubheadline.weight(.semibold))
                    .foregroundStyle(theme.accent.color)
                    .frame(minHeight: 44)
                    Text("Your notebooks stay on this device. Sign in any time to sync them and use NOVA.")
                        .font(.dsCaption)
                        .foregroundStyle(theme.inkSecondary.color)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 4)
            }
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
            _ = await services.auth.signIn(email: email, password: password)
        }
    }
}

/// "Forgot password?" — a full screen (NOT a bottom sheet), top-aligned: an
/// email field, a send button, the server's message, and the expiry note.
///
/// Email only. The ClassMate version offered an SMS channel because a school
/// account has a verified phone number on file; a ClassNotes account is an email
/// and a password, so there is nowhere to text.
struct ForgotPasswordScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let prefill: String
    @State private var email: String
    @State private var busy = false
    @State private var message: String?
    @State private var success = false

    init(prefill: String) {
        self.prefill = prefill
        self._email = State(initialValue: prefill)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Forgot password")
                        .font(.dsTitle.weight(.heavy))
                        .foregroundStyle(theme.ink.color)
                    Text("Enter your email and we'll send you a reset link.")
                        .font(.dsBody)
                        .foregroundStyle(theme.inkSecondary.color)
                        .lineSpacing(3)
                        .padding(.top, 8)

                    HStack(spacing: 10) {
                        Image(systemName: "at").foregroundStyle(theme.inkSecondary.color).frame(width: 20)
                        TextField("Email", text: $email)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .foregroundStyle(theme.ink.color)
                            .submitLabel(.send)
                            .onSubmit(submit)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 14)
                    .background(theme.surfaceRaised.color.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.separator.color.opacity(0.6), lineWidth: 0.5))
                    .padding(.top, 24)

                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if busy {
                                BrandLoader(size: 18, tint: theme.contrastingInk(on: theme.accent).color)
                            } else {
                                Image(systemName: "paperplane.fill")
                                Text("Email me a reset link").font(.dsHeadline)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(busy || email.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.top, 20)

                    if let message {
                        Label {
                            Text(message).foregroundStyle(theme.ink.color)
                        } icon: {
                            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(success ? Color.green : Color.orange)
                        }
                        .font(.dsSubheadline)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((success ? Color.green : Color.orange).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, 18)
                    }

                    Text("The link expires in 1 hour and can only be used once.")
                        .font(.dsFootnote)
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
            let result = await services.auth.requestPasswordReset(email: email)
            busy = false
            success = result.sent
            // The server deliberately answers the same way for an address with no
            // account, so this must not be reworded into a confirmation that one
            // exists.
            message = result.message ?? (result.sent
                ? "If that email has a ClassNotes account, a reset link is on its way."
                : "We couldn't send a reset link. Check the address and try again.")
        }
    }
}
