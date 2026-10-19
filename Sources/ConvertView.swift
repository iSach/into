import AppKit
import SwiftUI

@MainActor
final class ConvertModel: ObservableObject {
    let source: Source
    let suggestions: [String]
    @Published var query = "" { didSet { refreshPreview() } }
    @Published var picked: String? { didSet { refreshPreview() } }
    @Published var scale = 1.0 { didSet { refreshPreview() } }
    @Published var imageQuality = 0.85 { didSet { refreshPreview() } }
    @Published var videoTarget = 1.0 { didSet { refreshPreview() } }
    @Published private(set) var preview = ""
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    private let onDone: (URL) -> Void
    private var previewGeneration = 0
    private var process: Process?
    private var cancelled = false

    init(source: Source, onDone: @escaping (URL) -> Void) {
        self.source = source
        self.onDone = onDone
        suggestions = Formats.suggestions(for: source)
        refreshPreview()
    }

    private var typed: String {
        Formats.normalize(query.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }

    /// Typing picks the matching suggestion; for audio/video an unknown extension is used as-is, since ffmpeg knows far more.
    var selected: String? {
        let typed = typed
        if typed.isEmpty { return picked ?? suggestions.first }
        if suggestions.contains(typed) { return typed }
        if let prefix = suggestions.first(where: { $0.hasPrefix(typed) }) { return prefix }
        return Formats.route(source, to: typed) != nil ? typed : nil
    }

    var customSelected: Bool { selected.map { !suggestions.contains($0) } ?? false }

    func pick(_ ext: String) {
        query = ""
        picked = ext
    }
    var busy: Bool { progress != nil }
    var compressible: Bool { selected.map { Formats.compressible(source, to: $0) } ?? false }
    var isVideoOutput: Bool { compressible && source.kind == .video }
    private var quality: Double { source.kind == .video ? videoTarget : imageQuality }

    private func refreshPreview() {
        previewGeneration += 1
        let generation = previewGeneration
        guard let ext = selected, compressible else { preview = ""; return }
        if source.kind == .video {
            guard ext != "gif" else { preview = ""; return }
            if let kbps = Converter.videoKbps(source, fraction: videoTarget) {
                preview = describe(Int64(Double(kbps + 128) * 1000 / 8 * source.duration))
            } else {
                preview = videoTarget < 1 ? "Size unknown" : "Original quality"
            }
            return
        }
        preview = "Estimating…"
        let source = source, scale = scale, quality = imageQuality
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            // Image previews are exact: encode for real, just don't write.
            let text: String
            do { text = try "\(Converter.imageData(source, ext: ext, scale: scale, quality: quality).count)" } catch { text = "" }
            DispatchQueue.main.async {
                guard let self, generation == self.previewGeneration else { return }
                self.preview = Int64(text).map(self.describe) ?? "Can't preview"
            }
        }
    }

    private func describe(_ bytes: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        guard source.bytes > 0 else { return "≈ \(size)" }
        let change = Int((Double(bytes) / Double(source.bytes) - 1) * 100)
        return "≈ \(size) (\(change > 0 ? "+" : "")\(change)%)"
    }

    func convert() {
        guard !busy, let ext = selected else { return }
        progress = 0
        error = nil
        let source = source, scale = compressible ? scale : 1, quality = quality
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try Converter.convert(source, to: ext, scale: scale, quality: quality,
                                      started: { process in DispatchQueue.main.async { self?.process = process } },
                                      progress: { value in DispatchQueue.main.async { self?.progress = value } })
            }
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        process = nil
        switch result {
        case .success(let url) where cancelled:
            try? FileManager.default.removeItem(at: url)
        case .success(let url):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
            onDone(url)
        case .failure(let failure):
            progress = nil
            error = failure.localizedDescription
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }
}

struct ConvertView: View {
    @ObservedObject var model: ConvertModel
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: model.source.url.path))
                    .resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.source.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(model.source.summary).font(.caption).foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(model.suggestions, id: \.self) { ext in
                    Text(ext.uppercased())
                        .chip(selected: ext == model.selected)
                        .contentShape(Rectangle())
                        .onTapGesture { model.pick(ext) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Convert to \(ext)")
                }
                TextField("other", text: $model.query)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .chip(selected: model.customSelected)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: focused && !model.customSelected ? 1.5 : 0))
                    .focused($focused)
                    .onSubmit(model.convert)
                    .disabled(model.busy)
                    .accessibilityLabel("Other format")
            }
            if model.selected == nil {
                Text("No converter for “\(model.query)”").font(.callout).foregroundStyle(.secondary)
            }

            if model.compressible {
                Divider()
                Picker("Size", selection: $model.scale) {
                    Text("100%").tag(1.0)
                    Text("75%").tag(0.75)
                    Text("50%").tag(0.5)
                    Text("25%").tag(0.25)
                }
                .pickerStyle(.segmented)
                if model.isVideoOutput {
                    if model.selected != "gif" {
                        LabeledContent("Target") {
                            Slider(value: $model.videoTarget, in: 0.05...1) { EmptyView() } minimumValueLabel: {
                                Text("Smaller").font(.caption)
                            } maximumValueLabel: { Text("Auto").font(.caption) }
                        }
                    }
                } else {
                    LabeledContent("Quality") {
                        Slider(value: $model.imageQuality, in: 0.1...1) { EmptyView() } minimumValueLabel: {
                            Text("Smaller").font(.caption)
                        } maximumValueLabel: { Text("Best").font(.caption) }
                    }
                }
                if !model.preview.isEmpty {
                    Text(model.preview).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                if let progress = model.progress {
                    ProgressView(value: progress)
                }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(model.selected.map { "Convert to \($0.uppercased())" } ?? "Convert", action: model.convert)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selected == nil || model.busy)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } } // after the lazy grid builds the field
    }
}

private extension View {
    func chip(selected: Bool) -> some View {
        font(.system(.caption, design: .monospaced).weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.secondary.opacity(0.15)))
            .foregroundStyle(selected ? Color.white : Color.primary)
    }
}
