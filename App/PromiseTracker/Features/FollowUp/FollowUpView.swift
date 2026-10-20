import PromiseCore
import SwiftUI
import UIKit

/// "Follow up with AI" — an editable draft the user copies or shares themselves.
/// Nothing is ever sent by the app (FR-10).
struct FollowUpView: View {
    @Environment(AppModel.self) private var model
    let commitmentId: UUID

    @State private var text = ""
    @State private var kind: FollowUpKind = .statusUpdate
    @State private var tone: FollowUpTone = .friendly
    @State private var keyPoints = false
    @State private var isWorking = false
    @State private var customInstruction = ""
    @State private var showCustomise = false
    @State private var copied = false
    @State private var note: String?

    private var commitment: Commitment? { model.commitment(commitmentId) }
    private var aiAvailable: Bool { model.aiUnavailableReason == nil }

    /// Free plan: a few AI rewrites per week; template drafts are always available.
    private var aiRewritesLeft: Int? {
        guard !model.isPro else { return nil }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let used: Int = model.service.aiFollowUpCount(since: weekAgo)
        return max(0, EntitlementPolicy.freeFollowUpDraftsPerWeek - used)
    }

    var body: some View {
        ScrollView {
            if let c = commitment {
                VStack(spacing: 18) {
                    ScreenHeader(title: aiAvailable ? "Follow up with AI" : "Follow up",
                                 subtitle: "Here’s a suggested message\(model.personName(for: c).map { " to send to \($0)" } ?? ""). You can edit it before sending.",
                                 alignment: .center)
                    Picker("Message", selection: $kind) {
                        Text("Update").tag(FollowUpKind.statusUpdate)
                        Text("Running late").tag(FollowUpKind.apologyLate)
                        Text("It’s done").tag(FollowUpKind.delivered)
                        Text("Checking in").tag(FollowUpKind.checkingIn)
                    }
                    .pickerStyle(.segmented)

                    ZStack(alignment: .topTrailing) {
                        TextEditor(text: $text)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 260)
                            .font(.body)
                            .accessibilityLabel("Message draft")
                        if isWorking { ProgressView().padding(8) }
                    }
                    .card(padding: 14)

                    if let note { Text(note).font(.footnote).foregroundStyle(Theme.inkSecondary) }

                    VStack(alignment: .leading, spacing: 4) {
                        option("textformat", "Make it more formal") { apply(tone: .formal, instruction: "Make it more formal.") }
                        option("scissors", "Make it shorter") { apply(tone: .short, instruction: "Make it shorter.") }
                        option("list.bullet", "Add key points") { keyPoints = true; regenerate() }
                        if aiAvailable {
                            option("pencil", "Customise…") { showCustomise = true }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                        model.service.recordFollowUpDrafted(c.id)
                    } label: {
                        Label(copied ? "Copied" : "Copy Message", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.primary)
                    ShareLink(item: text) { Label("Share…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.secondary)
                    Text("Promise Tracker never sends messages for you. Paste it wherever you talk to them.")
                        .font(.caption).foregroundStyle(Theme.inkTertiary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 30)
                .onAppear {
                    kind = FollowUpTemplates().suggestedKind(for: c, isOverdue: model.isOverdue(c))
                    regenerate()
                }
                .onChange(of: kind) { _, _ in regenerate() }
            }
        }
        .canvasBackground()
        .alert("What should change?", isPresented: $showCustomise) {
            TextField("e.g. mention I’ll call on Monday", text: $customInstruction)
            Button("Rewrite") { Task { await rewrite(customInstruction) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func option(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline).foregroundStyle(Theme.inkSecondary).padding(.vertical, 6)
        }
        .disabled(isWorking)
    }

    private func regenerate() {
        guard let c = commitment else { return }
        let points = keyPoints ? (c.notes?.split(whereSeparator: \.isNewline).map(String.init) ?? []) + (c.nextAction.map { [$0] } ?? []) : []
        text = FollowUpTemplates().draft(for: c, recipient: model.personName(for: c), sender: model.userName,
                                         kind: kind, tone: tone, keyPoints: points)
        copied = false
        if keyPoints && points.isEmpty { note = "Add notes to this promise to include key points." } else { note = nil }
    }

    private func apply(tone newTone: FollowUpTone, instruction: String) {
        tone = newTone
        regenerate()
        if aiAvailable { Task { await rewrite(instruction) } }
    }

    private func rewrite(_ instruction: String) async {
        guard aiAvailable, !instruction.isEmpty else { return }
        if let left = aiRewritesLeft, left == 0 {
            note = "You’ve used this week’s free AI rewrites. Template drafts still work; Pro removes the limit."
            return
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            isWorking = true
            defer { isWorking = false }
            do {
                text = try await FoundationModelFollowUpWriter().rewrite(text, instruction: instruction)
                copied = false
                model.service.recordFollowUpDrafted(commitmentId, usedAI: true)
                model.reload()
            } catch {
                note = "On-device AI couldn’t rewrite this. The template is still here to edit."
            }
        }
        #endif
    }
}
