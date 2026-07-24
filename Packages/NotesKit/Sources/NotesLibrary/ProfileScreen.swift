import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// The signed-in user's profile, mirroring ClassMate: avatar with initials,
/// display name, @username, role/school/cohort badges, and account info.
public struct ProfileScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var confirmLogout = false

    public init() {}

    private var user: ClassMateUser? { services.auth.user }

    public var body: some View {
        NavigationStack {
            List {
                header
                if let user, let role = user.primaryRole {
                    Section("School") {
                        infoRow("Role", role.capitalized, "person.badge.shield.checkmark")
                        if let school = user.schoolName {
                            infoRow("School", school, "building.columns")
                        }
                        if let cohort = user.cohortName {
                            infoRow("Cohort", cohort, "person.3")
                        }
                        if let grade = user.grade {
                            infoRow("Grade", "\(grade)", "number")
                        }
                    }
                    .listRowBackground(theme.surfaceRaised.color)
                }
                Section("Account") {
                    if let email = user?.email {
                        infoRow("Email", email, "envelope")
                    }
                    if let username = user?.username {
                        infoRow("Username", "@\(username)", "at")
                    }
                    if let phone = user?.phone {
                        infoRow("Phone", phone, "phone")
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
            .confirmationDialog(
                "Log out of ClassMate?",
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
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(theme.accentMuted.color)
                Text(user?.initials ?? "?")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(theme.accent.color)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(user?.bestName ?? "Student")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(theme.ink.color)
                if let username = user?.username {
                    Text("@\(username)")
                        .font(.subheadline)
                        .foregroundStyle(theme.accent.color)
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
