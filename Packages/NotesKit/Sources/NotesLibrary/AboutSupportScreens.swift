import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

public enum ClassMateLinks {
    public static let legalHome = URL(string: "https://tony11-dot.github.io/classmate-legal/")!
    public static let privacy = URL(string: "https://tony11-dot.github.io/classmate-legal/privacy.html")!
    public static let supportEmail = "support@classmateapp.org"
    public static let supportPhone = "+972525488441"
    public static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return v
    }
}

/// Support: talk-to-us card, Ask NOVA, and FAQ — mirrors ClassMate's support.
public struct SupportScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    @State private var showNova = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showNova = true
                    } label: {
                        HStack(spacing: 12) {
                            NovaAvatar(size: 40)
                            VStack(alignment: .leading) {
                                Text("Ask NOVA").font(.headline).foregroundStyle(theme.ink.color)
                                Text("Get instant help, any time.")
                                    .font(.caption).foregroundStyle(theme.inkSecondary.color)
                            }
                        }
                    }
                }
                .listRowBackground(theme.surfaceRaised.color)

                Section("Talk to us") {
                    Link(destination: URL(string: "mailto:\(ClassMateLinks.supportEmail)")!) {
                        Label(ClassMateLinks.supportEmail, systemImage: "envelope")
                    }
                    Link(destination: URL(string: "tel:\(ClassMateLinks.supportPhone)")!) {
                        Label(ClassMateLinks.supportPhone, systemImage: "phone")
                    }
                }
                .listRowBackground(theme.surfaceRaised.color)

                Section("FAQ") {
                    faq("How do I create a notebook?",
                        """
                        On iPad, tap + in the library. Pick a cover and a \
                        first-page template, then write with your Apple Pencil.
                        """)
                    faq("Can I edit on iPhone?",
                        "iPhone is a read-only viewer — browse, read and share. Create and edit on iPad.")
                    faq("How does NOVA work?",
                        "Circle anything on a page and NOVA explains it. Add a free Groq API key in Settings to turn it on.")
                    faq("Where are my notes stored?",
                        "On your device, as self-contained notebook files. iCloud sync is coming.")
                }
                .listRowBackground(theme.surfaceRaised.color)
            }
            .scrollContentBackground(.hidden)
            .background(theme.surface.color)
            .navigationTitle("Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showNova) {
                NovaSupportSheet()
            }
        }
    }

    private func faq(_ q: String, _ a: String) -> some View {
        DisclosureGroup {
            Text(a).font(.subheadline).foregroundStyle(theme.inkSecondary.color)
        } label: {
            Text(q).font(.subheadline.weight(.semibold)).foregroundStyle(theme.ink.color)
        }
    }
}

/// About: what the app is + version stamp, mirroring ClassMate's About.
public struct AboutScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack { Spacer(); BrandMark(size: 72); Spacer() }
                        .padding(.top, 8)
                    block("What is ClassNotes?",
                          """
                          ClassNotes is a native note-taking studio for \
                          students — handwriting, drawing, voice, media and AI \
                          in one place, themed to match ClassMate.
                          """)
                    block("Privacy first",
                          """
                          Your notebooks stay on your device. No third-party \
                          trackers, no ad networks. AI requests use a key you \
                          provide and control.
                          """)
                    block("Contact",
                          "Built by the ClassMate team.\nQuestions: \(ClassMateLinks.supportEmail)")
                    Link("Privacy Policy", destination: ClassMateLinks.privacy)
                        .foregroundStyle(theme.accent.color)
                    Text("ClassNotes · v\(ClassMateLinks.appVersion)")
                        .font(.caption)
                        .foregroundStyle(theme.inkSecondary.color)
                }
                .padding(20)
            }
            .background(theme.surface.color)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func block(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(theme.accent.color)
            Text(body).font(.subheadline).foregroundStyle(theme.inkSecondary.color)
        }
    }
}
