import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// Making a new account from inside ClassNotes.
///
/// The account it creates is a REAL ClassMate account, not a ClassNotes-only
/// one. That is deliberate: everything the app already does — the library
/// mirror, page renders, NOVA answering through `/classnotes/ai` — is
/// authenticated with a ClassMate session, and a parallel account space would
/// mean either building all of that a second time or quietly losing the notes
/// made under it. Signing up here and signing in on ClassMate lands you in the
/// same place, with the same notebooks in the ClassNotes tab.
public struct SignUpScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case name, email, password, confirmation }

    public init() {}

    /// What's wrong with the form right now, or nil when it's ready to send.
    /// Checked here rather than only on the server so the answer is instant and
    /// doesn't cost a round trip to learn.
    var validationError: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter your name." }
        guard email.contains("@"), email.contains(".") else { return "Enter a valid email." }
        guard password.count >= 8 else { return "Use at least 8 characters." }
        guard password == confirmation else { return "Those passwords don't match." }
        return nil
    }

    public var body: some View {
        ZStack {
            AmbientBackground(seed: 8)
            GeometryReader { geo in
                ScrollView {
                    card
                        .frame(maxWidth: 400)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        .padding(.horizontal, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            BrandLockup(height: 48)
            VStack(spacing: 4) {
                Text("Create your account")
                    .font(.dsTitle2.weight(.bold))
                    .foregroundStyle(theme.ink.color)
                Text("One account for ClassNotes and ClassMate.")
                    .font(.dsSubheadline)
                    .foregroundStyle(theme.inkSecondary.color)
                    .multilineTextAlignment(.center)
            }

            AuthField(text: $name, placeholder: "Full name", systemImage: "person")
                .textContentType(.name)
                .submitLabel(.next)
                .focused($focus, equals: .name)
                .onSubmit { focus = .email }

            AuthField(text: $email, placeholder: "Email", systemImage: "at")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .submitLabel(.next)
                .focused($focus, equals: .email)
                .onSubmit { focus = .password }

            AuthField(
                text: $password, placeholder: "Password", systemImage: "lock", secure: true
            )
            .textContentType(.newPassword)
            .submitLabel(.next)
            .focused($focus, equals: .password)
            .onSubmit { focus = .confirmation }

            AuthField(
                text: $confirmation, placeholder: "Confirm password",
                systemImage: "lock.rotation", secure: true
            )
            .textContentType(.newPassword)
            .submitLabel(.go)
            .focused($focus, equals: .confirmation)
            .onSubmit { submit() }

            if let message = error ?? services.auth.lastError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.dsFootnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                Group {
                    if busy {
                        BrandLoader(size: 22, tint: theme.contrastingInk(on: theme.accent).color)
                    } else {
                        Text("Create account").font(.dsHeadline)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.glassProminent)
            .disabled(busy)

            Button("I already have an account") { dismiss() }
                .font(.dsSubheadline.weight(.medium))
                .foregroundStyle(theme.accent.color)
                .buttonStyle(.plain)
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

    /// Seeds the form so the validation rules can be tested without a UI host.
    mutating func setForTesting(
        name: String, email: String, password: String, confirmation: String
    ) {
        _name = State(initialValue: name)
        _email = State(initialValue: email)
        _password = State(initialValue: password)
        _confirmation = State(initialValue: confirmation)
    }

    private func submit() {
        error = validationError
        guard error == nil, !busy else { return }
        busy = true
        Task {
            let created = await services.auth.register(
                email: email.trimmingCharacters(in: .whitespaces),
                name: name.trimmingCharacters(in: .whitespaces),
                password: password
            )
            busy = false
            // On success the auth state flips to `.authenticated` and the root
            // routes straight into the library; nothing left to dismiss.
            if !created, services.auth.lastError == nil {
                error = "Couldn't create that account. Try a different email."
            }
        }
    }
}

/// One labelled field in the auth cards, so sign-in and sign-up look like the
/// same screen rather than two screens that resemble each other.
struct AuthField: View {
    @Environment(\.theme) private var theme

    @Binding var text: String
    let placeholder: String
    let systemImage: String
    var secure = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(theme.inkSecondary.color)
                .frame(width: 20)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .foregroundStyle(theme.ink.color)
            .font(.dsBody)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.separator.color, lineWidth: 0.5)
        )
    }
}
