import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

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
                                Text("Ask NOVA").font(.dsHeadline).foregroundStyle(theme.ink.color)
                                Text("Get instant help, any time.")
                                    .font(.dsCaption).foregroundStyle(theme.inkSecondary.color)
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
                        On iPad, tap + in the library. Take a quick note, build a \
                        full notebook, open a whiteboard, or bring in a photo, a \
                        file or a scan — then write with your Apple Pencil.
                        """)
                    faq("Can I edit on iPhone?",
                        """
                        iPhone is a read-only viewer — browse, read, zoom in, play \
                        voice notes, open files and share. Create and edit on iPad.
                        """)
                    faq("How does NOVA work?",
                        """
                        Snip anything on a page and NOVA explains it, or tap \
                        Read this notebook and ask about all of it; answers say \
                        which pages they came from. Chats are saved with the \
                        notebook. NOVA asks before it sends anything, and works \
                        while you're signed in.
                        """)
                    faq("Where are my notes stored?",
                        """
                        On your device, as self-contained notebook files. A \
                        picture of each page also syncs to your ClassNotes \
                        account so the ClassMate app can show it.
                        """)
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
            Text(a).font(.dsSubheadline).foregroundStyle(theme.inkSecondary.color)
        } label: {
            Text(q).font(.dsSubheadline.weight(.semibold)).foregroundStyle(theme.ink.color)
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
                          Your notebooks are kept on your device. Page pictures \
                          sync to your ClassNotes account so the ClassMate app \
                          can show them. No third-party trackers, no ad \
                          networks. NOVA only sees what you send it, after you \
                          allow it, through our servers to Groq, the AI \
                          service that writes its replies.
                          """)
                    block("Contact",
                          "Built by the ClassMate team.\nQuestions: \(ClassMateLinks.supportEmail)")
                    Link("Privacy Policy", destination: ClassMateLinks.privacy)
                        .foregroundStyle(theme.accent.color)
                    Link("Accessibility", destination: ClassMateLinks.accessibility)
                        .foregroundStyle(theme.accent.color)
                    Text("ClassNotes · v\(ClassMateLinks.appVersion)")
                        .font(.dsCaption)
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
            Text(title).font(.dsHeadline).foregroundStyle(theme.accent.color)
            Text(body).font(.dsSubheadline).foregroundStyle(theme.inkSecondary.color)
        }
    }
}
