import PromiseCore
import SwiftUI

/// speak/type → editable transcript → review drafts → explicit save → saved.
struct CaptureFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: CaptureRequest

    enum Stage: Equatable { case listening, editing, processing, review, saved }

    @State private var stage: Stage = .editing
    @State private var transcriber = SpeechTranscriber()
    @State private var text = ""
    @State private var source: SourceType = .text
    @State private var drafts: [DraftCommitment] = []
    @State private var skipped: [SkippedStatement] = []
    @State private var fallbackReason: ExtractionUnavailableReason?
    @State private var saved: [Commitment] = []
    @State private var confirmDiscard = false
    @State private var editedDrafts = false

    private var hasSubstance: Bool {
        stage != .saved && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !drafts.isEmpty || editedDrafts)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .listening: listening
                case .editing: CaptureTextEditor(text: $text, fromVoice: source == .voice, speechNote: speechNote,
                                                 onContinue: interpret, onRecordAgain: startListening, onManual: startManual)
                case .processing: processing
                case .review:
                    ReviewView(drafts: $drafts, skipped: skipped, fallbackReason: fallbackReason, edited: $editedDrafts,
                               onSaved: { commitments in
                                   saved.append(contentsOf: commitments)
                                   if drafts.isEmpty { withAnimation { stage = .saved } }
                               }, onBack: { stage = .editing })
                case .saved:
                    SavedView(saved: saved, onAddAnother: reset, onView: { id in
                        dismiss()
                        model.open(.commitment(id))
                    }, onDone: { dismiss() })
                }
            }
            .toolbar {
                if stage != .saved {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { hasSubstance ? (confirmDiscard = true) : close() }
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            .canvasBackground()
        }
        .interactiveDismissDisabled(hasSubstance)
        .confirmationDialog("Discard this promise?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { close() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Nothing has been saved yet.")
        }
        .task { await begin() }
        .onDisappear { transcriber.reset() }
    }

    // MARK: Stages

    private var listening: some View {
        VStack(spacing: 24) {
            Spacer()
            GlowOrb(level: transcriber.levels.last ?? 0)
            VStack(spacing: 8) {
                Text(transcriber.state == .requestingPermission ? "One moment…" : "I’m listening…")
                    .font(Theme.display(.largeTitle))
                    .foregroundStyle(Theme.ink)
                Text("Speak naturally about your promise.")
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)
            }
            if !transcriber.transcript.isEmpty {
                Text(transcriber.transcript)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .padding(.horizontal, 28)
                    .accessibilityLabel("Heard so far: \(transcriber.transcript)")
            }
            WaveformView(levels: transcriber.levels)
                .padding(.horizontal, 40)
            Spacer()
            Button(action: stopListening) {
                ZStack {
                    Circle().fill(Theme.card).shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                    RoundedRectangle(cornerRadius: 5).fill(Theme.warm).frame(width: 22, height: 22)
                }
                .frame(width: 72, height: 72)
            }
            .accessibilityLabel("Stop recording")
            Button("Type instead") { stopListening() }
                .font(.subheadline).foregroundStyle(Theme.inkSecondary)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Theme.canvas, Color(light: 0xF3DCC6, dark: 0x2A211C)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .onChange(of: transcriber.state) { _, state in
            switch state {
            case .stopped, .interrupted, .unavailable:
                text = transcriber.transcript
                stage = .editing
            default: break
            }
        }
    }

    private var speechNote: String? {
        switch transcriber.state {
        case let .unavailable(message), let .interrupted(message): return message
        default:
            if source == .voice && !transcriber.isOnDevice && !transcriber.transcript.isEmpty {
                return "This iPhone sent your audio to Apple’s speech service to transcribe it."
            }
            return nil
        }
    }

    private var processing: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Reading your promise…").font(Theme.display(.title2)).foregroundStyle(Theme.ink)
            Text("This happens on your iPhone.").font(.footnote).foregroundStyle(Theme.inkSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Flow

    private func begin() async {
        source = request.source
        if !request.prefill.isEmpty {
            text = request.prefill
            interpret()
            return
        }
        switch request.mode {
        case .voice: startListening()
        case .text: stage = .editing
        case .manual: startManual()
        }
    }

    private func startListening() {
        source = .voice
        transcriber.transcript = text
        stage = .listening
        Task { await transcriber.start() }
    }

    private func stopListening() {
        if transcriber.isListening { transcriber.stop() } else {
            text = transcriber.transcript
            stage = .editing
        }
    }

    private func interpret() {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        stage = .processing
        Task {
            let result = await model.env.interpret(input, source: source == .voice ? .voice : request.source)
            drafts = result.drafts.map { draft in
                var d = draft
                if let pid = request.personId, d.personMatch == .none { d.choosePerson(pid) }
                return d
            }
            skipped = result.skipped
            fallbackReason = result.fallbackReason
            if drafts.isEmpty {
                // Nothing recognizable: fall back to the manual form, keeping the words.
                drafts = [manualDraft(title: input)]
                drafts[0].uncertainFields.insert(.title)
            }
            stage = .review
        }
    }

    private func startManual() {
        drafts = [manualDraft(title: text.trimmingCharacters(in: .whitespacesAndNewlines))]
        skipped = []
        fallbackReason = nil
        stage = .review
    }

    private func manualDraft(title: String) -> DraftCommitment {
        var d = model.env.makeInterpreter().manualDraft(title: title, personName: nil, duePhrase: nil, capturedAt: Date(),
                                                        people: model.people, existing: model.commitments, source: .manual)
        d.rawText = text
        if let pid = request.personId { d.choosePerson(pid) }
        return d
    }

    private func reset() {
        transcriber.reset()
        text = ""
        drafts = []
        skipped = []
        saved = []
        editedDrafts = false
        startListening()
    }

    private func close() {
        transcriber.reset()
        dismiss()
    }
}

/// Editable transcript / typing area (FR-01: transcript editable before extraction).
struct CaptureTextEditor: View {
    @Binding var text: String
    let fromVoice: Bool
    let speechNote: String?
    let onContinue: () -> Void
    let onRecordAgain: () -> Void
    let onManual: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: fromVoice ? "Here’s what I heard" : "What did you promise?",
                         subtitle: fromVoice ? "Fix anything before I read it." : "Write it the way you’d say it.")
            if let speechNote { NoticeBanner(icon: "mic.slash", text: speechNote) }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("I promised Sarah I’d send the revised proposal by Thursday…")
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .accessibilityLabel("Promise text")
            }
            .card(padding: 12)

            Button(action: onContinue) { Label("Continue", systemImage: "sparkles") }
                .buttonStyle(.primary)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            HStack {
                Button(action: onRecordAgain) { Label(fromVoice ? "Keep talking" : "Speak instead", systemImage: "mic") }
                Spacer()
                Button("Fill in details myself", action: onManual)
            }
            .font(.subheadline)
            .foregroundStyle(Theme.inkSecondary)
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 8)
        .onAppear { if !fromVoice || text.isEmpty { focused = true } }
    }
}
