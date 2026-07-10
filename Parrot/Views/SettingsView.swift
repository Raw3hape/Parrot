import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    /// True when rendered inside the main window's detail pane (wide, fills the
    /// space); false for the standalone Cmd-, Settings window, which needs a
    /// fixed sane size.
    var isEmbedded = false

    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage = "auto"
    @AppStorage("customVocabulary") private var customVocabulary = ""
    @AppStorage("echoCancellationEnabled") private var echoCancellation = true
    @State private var showFileImporter = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            audioTab
                .tabItem {
                    Label("Audio", systemImage: "waveform")
                }

            ProfilesSettingsView()
                .tabItem {
                    Label("Profiles", systemImage: "person.2.badge.gearshape")
                }

            knowledgeTab
                .tabItem {
                    Label("Knowledge", systemImage: "books.vertical")
                }

            appearanceTab
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
        }
        .frame(width: isEmbedded ? nil : 520, height: isEmbedded ? nil : 440)
        .frame(maxWidth: isEmbedded ? .infinity : nil,
               maxHeight: isEmbedded ? .infinity : nil)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Local Transcription") {
                LabeledContent("Primary model") {
                    Text("NVIDIA Parakeet TDT 0.6B V3")
                        .fontWeight(.medium)
                }
                LabeledContent("Fallback model") {
                    Text("Whisper Large V3 Turbo")
                }
                LabeledContent("Speech detection") {
                    Text("Silero VAD")
                }

                modelStatusView

                Button("Download / Reload Local Models") {
                    Task {
                        await recordingManager.transcriptionEngine.loadModel()
                    }
                }

                Label("Free and on-device. Call audio and transcript text never go to a cloud service.",
                      systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription Language") {
                Picker("Language", selection: $transcriptionLanguage) {
                    Text("Auto-detect").tag("auto")
                    Text("Polish").tag("pl")
                    Text("Russian").tag("ru")
                    Text("English").tag("en")
                }
                Text("Auto-detect is recommended when Polish, Russian, and English may appear in the same call. A fixed language applies from the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom Vocabulary") {
                TextEditor(text: $customVocabulary)
                    .frame(height: 64)
                    .font(.callout)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.2)))
                Text("Names, products, or jargon the local models keep mis-hearing — comma or line separated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var modelStatusView: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .ready:
            Label("Model loaded and ready", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .font(.caption)
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .font(.caption)
        default:
            EmptyView()
        }
    }

    // MARK: - Audio Tab

    private var audioTab: some View {
        Form {
            Section("Input") {
                Text("System audio is always captured via ScreenCaptureKit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Microphone uses your default input device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Echo Cancellation") {
                Toggle("Cancel speaker echo from the mic", isOn: $echoCancellation)
                Text("When you're on speakers (no headphones), your mic also picks up the other person. This subtracts that echo so only your voice is recorded as \"Me\". Turn off if you always use headphones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                let path = AudioCaptureManager.storageDirectory().path
                LabeledContent("Audio files") {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
            }
        }
        .padding()
    }

    // MARK: - Knowledge Tab

    private var knowledgeTab: some View {
        Form {
            Section("Documents") {
                Text("Drop in pricing sheets, FAQs, playbooks — the copilot grounds its suggested answers in them and cites the source. Everything is indexed on this Mac; documents are never uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if recordingManager.knowledgeBase.documents.isEmpty {
                    Text("No documents yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(recordingManager.knowledgeBase.documents) { document in
                        KBDocumentRow(document: document, knowledgeBase: recordingManager.knowledgeBase)
                    }
                }

                HStack {
                    Button("Add Documents…") {
                        showFileImporter = true
                    }

                    if recordingManager.knowledgeBase.isIndexing {
                        ProgressView()
                            .controlSize(.small)
                        Text("Indexing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = recordingManager.knowledgeBase.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding()
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, .text],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task {
                    await recordingManager.knowledgeBase.addDocuments(at: urls)
                }
            }
        }
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appearance) {
                    Text("Follow System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.radioGroup)
            }
        }
        .padding()
    }
}

enum Appearance: String, CaseIterable {
    case system, light, dark
}

// MARK: - Knowledge Base Document Row

struct KBDocumentRow: View {
    let document: KBDocument
    let knowledgeBase: KnowledgeBaseService

    @State private var note: String

    init(document: KBDocument, knowledgeBase: KnowledgeBaseService) {
        self.document = document
        self.knowledgeBase = knowledgeBase
        _note = State(initialValue: document.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: document.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                    .foregroundStyle(.secondary)

                Text(document.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text("\(document.chunkCount) chunks")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    knowledgeBase.removeDocument(document)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Remove from knowledge base")
            }

            TextField(
                "When should the copilot use this? e.g. \"use for pricing questions\"",
                text: $note
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .onSubmit {
                knowledgeBase.updateNote(note, for: document)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Provider API key field

/// Reusable BYO-key field with the same save/verify UX as the Claude key:
/// Keychain-backed, explicit Save, and a visible error when the write fails.
struct ProviderKeyField: View {
    let label: String
    let account: String
    let placeholder: String
    let hint: String

    @State private var key: String
    @State private var saved = false
    @State private var failed = false

    init(label: String, account: String, placeholder: String, hint: String) {
        self.label = label
        self.account = account
        self.placeholder = placeholder
        self.hint = hint
        _key = State(initialValue: APIKeyStore.load(account: account) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField(placeholder, text: $key, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .onChange(of: key) {
                    saved = false
                    failed = false
                }

            HStack {
                Button("Save \(label)") {
                    failed = !APIKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines),
                                               account: account)
                    saved = !failed
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if saved {
                    Label("Saved", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else if failed {
                    Label("Keychain rejected the key — try again", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
