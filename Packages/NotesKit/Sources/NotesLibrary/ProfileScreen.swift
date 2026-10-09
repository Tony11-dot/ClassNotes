import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// The signed-in account: avatar initial, name, email, and the three things a
/// user can do to their own account — rename it, change its password, delete it.
///
/// This is a ClassNotes account, so there is no role, school or cohort to show
/// any more; those belonged to the ClassMate school profile the app used to
/// borrow. What replaced them is the account management that was previously
/// impossible: "Delete Account" used to be a LINK out to a ClassMate web page,
/// because the app had no endpoint of its own that could delete anything.
public struct ProfileScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var confirmLogout = false
    @State private var showRename = false
    @State private var showChangePassword = false
    @State private var showDelete = false

    public init() {}

    private var account: ClassNotesAccount? { services.auth.account }

    public var body: some View {
        NavigationStack {
            List {
                header
                Section("Account") {
                    if let email = account?.email {
                        infoRow("Email", email, "envelope")
                    }
                    if let joined = account?.createdAt {
                        infoRow("Joined", joined.formatted(date: .abbreviated, time: .omitted), "calendar")
                    }
                    Button { showRename = true } label: {
                        Label("Change name", systemImage: "pencil")
                    }
                    Button { showChangePassword = true } label: {
                        Label("Change password", systemImage: "lock.rotation")
                    }
                }
                .listRowBackground(theme.surfaceRaised.color)

                Section {
                    Button(role: .destructive) {
                        confirmLogout = true
                    } label: {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                .listRowBackground(theme.surfaceRaised.color)

                Section {
                    Button(role: .destructive) { showDelete = true } label: {
                        Label("Delete account", systemImage: "trash")
                    }
                } footer: {
                    Text(
                        "Permanently deletes your ClassNotes account and everything synced to "
                        + "it. The notebooks already on this iPad are your own files and stay "
                        + "where they are."
                    )
                }
                .listRowBackground(theme.surfaceRaised.color)
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface.color)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showRename) {
                RenameAccountSheet(current: account?.name ?? "")
            }
            .sheet(isPresented: $showChangePassword) { ChangePasswordSheet() }
            .sheet(isPresented: $showDelete) { DeleteAccountSheet() }
            .confirmationDialog(
                "Log out of ClassNotes?",
                isPresented: $confirmLogout,
                titleVisibility: .visible
            ) {
                Button("Log out", role: .destructive) {
                    services.auth.signOut()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your notebooks stay on this device. You'll need to sign in again to sync.")
            }
            // Deleting the account leaves the library open (the notebooks are
            // the user's own files), so the profile closes itself.
            .onChange(of: services.auth.state) { _, state in
                if state == .signedOut { dismiss() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(theme.accentMuted.color)
                Text(account?.initial ?? "?")
                    .font(.dsTitle2.weight(.heavy))
                    .foregroundStyle(theme.accent.color)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(account?.displayName ?? "Student")
                    .font(.dsTitle3.weight(.heavy))
                    .foregroundStyle(theme.ink.color)
                if let email = account?.email {
                    Text(email)
                        .font(.dsSubheadline)
                        .foregroundStyle(theme.inkSecondary.color)
                }
            }
            Spacer()
        }
        .listRowBackground(theme.surfaceRaised.color)
    }

    private func infoRow(_ label: String, _ value: String, _ symbol: String) -> some View {
        HStack {
            Label(label, systemImage: symbol)
                .foregroundStyle(theme.inkSecondary.color)
            Spacer()
            Text(value)
                .foregroundStyle(theme.ink.color)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Renaming the account. Saves to the server first — a name the server refused
/// must not be left on screen looking saved.
struct RenameAccountSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let current: String
    @State private var name: String
    @State private var busy = false
    @State private var error: String?

    init(current: String) {
        self.current = current
        _name = State(initialValue: current)
    }

    var body: some View {
        AccountSheet(title: "Change name", error: error, busy: busy, canSubmit: canSubmit) {
            AuthField(text: $name, placeholder: "Your name", systemImage: "person")
                .textContentType(.name)
        } submit: {
            busy = true
            Task {
                let saved = await services.auth.updateName(name)
                busy = false
                if saved { dismiss() } else { error = services.auth.lastError ?? "Couldn't save your name." }
            }
        }
    }

    private var canSubmit: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != current
    }
}

/// Changing the password. The server hands back a replacement token, which
/// `AuthService` stores — so this device stays signed in while every other one
/// is signed out.
struct ChangePasswordSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        AccountSheet(
            title: "Change password",
            footer: "Signing in on your other devices will need the new password.",
            error: error,
            busy: busy,
            canSubmit: validationError == nil
        ) {
            AuthField(text: $current, placeholder: "Current password", systemImage: "lock", secure: true)
                .textContentType(.password)
            AuthField(text: $new, placeholder: "New password", systemImage: "lock.rotation", secure: true)
                .textContentType(.newPassword)
            AuthField(
                text: $confirmation, placeholder: "Confirm new password",
                systemImage: "lock.rotation", secure: true
            )
            .textContentType(.newPassword)
        } submit: {
            if let problem = validationError { error = problem; return }
            busy = true
            Task {
                let changed = await services.auth.changePassword(current: current, new: new)
                busy = false
                if changed { dismiss() } else { error = services.auth.lastError ?? "Couldn't change your password." }
            }
        }
    }

    /// Mirrors the server's own floor so the answer is instant and doesn't cost
    /// a round trip to learn.
    var validationError: String? {
        if current.isEmpty { return "Enter your current password." }
        if new.count < 8 { return "Use at least 8 characters." }
        if new != confirmation { return "Those passwords don't match." }
        return nil
    }
}

/// Deleting the account, which App Store guideline 5.1.1(v) requires to be
/// possible from inside the app. Asks for the password because it destroys
/// everything the account has on the server.
struct DeleteAccountSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        AccountSheet(
            title: "Delete account",
            footer: "This cannot be undone. Your account and everything synced to it are "
                + "deleted. The notebooks on this iPad stay on this iPad.",
            error: error,
            busy: busy,
            canSubmit: !password.isEmpty,
            submitLabel: "Delete my account",
            destructive: true
        ) {
            AuthField(text: $password, placeholder: "Your password", systemImage: "lock", secure: true)
                .textContentType(.password)
        } submit: {
            busy = true
            Task {
                let deleted = await services.auth.deleteAccount(password: password)
                busy = false
                // On success the auth state flips to `.signedOut`; the library
                // stays open and the profile closes itself, this sheet with it.
                if !deleted { error = services.auth.lastError ?? "Couldn't delete your account." }
            }
        }
    }
}

/// The shell the three account sheets share, so they look like one feature
/// rather than three screens that resemble each other.
struct AccountSheet<Fields: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let title: String
    var footer: String?
    let error: String?
    let busy: Bool
    let canSubmit: Bool
    var submitLabel = "Save"
    var destructive = false
    @ViewBuilder var fields: Fields
    let submit: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    fields
                    if let footer {
                        Text(footer)
                            .font(.dsFootnote)
                            .foregroundStyle(theme.inkSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.dsFootnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(action: submit) {
                        Group {
                            if busy {
                                BrandLoader(size: 20, tint: theme.contrastingInk(on: theme.accent).color)
                            } else {
                                Text(submitLabel).font(.dsHeadline)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(destructive ? .red : theme.accent.color)
                    .disabled(busy || !canSubmit)
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .background(theme.surface.color.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
