import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum Kind { case image, pdf, video, audio, document }

struct ConvertError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct Source {
    let url: URL
    let kind: Kind
    let ext: String
    let bytes: Int64
    var pixels = CGSize.zero
    var duration = 0.0

    init?(url: URL) {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values?.isRegularFile == true else { return nil }
        let ext = Formats.normalize(url.pathExtension)
        let type = values?.contentType ?? UTType(filenameExtension: ext) ?? .data
        if type.conforms(to: .pdf) { kind = .pdf }
        else if type.conforms(to: .image) { kind = .image }
        else if type.conforms(to: .movie) || Formats.video.contains(ext) { kind = .video }
        else if type.conforms(to: .audio) || Formats.audio.contains(ext) { kind = .audio }
        else if Formats.document.contains(ext) { kind = .document }
        else { return nil }
        self.url = url
        self.ext = ext
        bytes = Int64(values?.fileSize ?? 0)
        if kind == .image, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            pixels = CGSize(width: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                            height: props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        if kind == .video || kind == .audio { probe() }
    }

    private mutating func probe() {
        guard let ffprobe = try? Tool.find("ffprobe") else { return }
        var lines: [String] = []
        try? Tool.run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration",
                                "-of", "default=nw=1", url.path], line: { lines.append($0) })
        let values = Dictionary(lines.compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { first, _ in first })
        duration = Double(values["duration"] ?? "") ?? 0
        pixels = CGSize(width: Int(values["width"] ?? "") ?? 0, height: Int(values["height"] ?? "") ?? 0)
    }

    var summary: String {
        var parts = [ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)]
        if pixels.width > 0 { parts.append("\(Int(pixels.width))×\(Int(pixels.height))") }
        if duration > 0 { parts.append(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)) }
        return parts.joined(separator: " · ")
    }
}

enum Formats {
    static let image = ["jpg", "png", "heic", "webp", "avif", "pdf", "tiff", "gif", "bmp"]
    static let video = ["mp4", "mov", "webm", "gif", "mkv", "m4v", "avi"]
    static let audio = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aac"]
    static let document = ["txt", "docx", "rtf", "html", "odt", "doc", "wordml", "webarchive"]

    static func normalize(_ ext: String) -> String {
        let ext = ext.lowercased()
        return ["jpeg": "jpg", "tif": "tiff", "htm": "html", "aif": "aiff", "heif": "heic"][ext] ?? ext
    }

    /// Most useful first. Image/video keep their own format last: re-encoding to it is how you compress.
    static func suggestions(for source: Source) -> [String] {
        let list: [String]
        switch source.kind {
        case .image: list = image
        case .pdf: return ["png", "jpg", "heic", "webp", "txt"]
        case .video: list = ["mp4", "mov", "webm", "gif", "mkv", "mp3", "m4a", "wav"]
        case .audio: return audio.filter { $0 != source.ext }
        case .document: return document.filter { $0 != source.ext }
        }
        let others = list.filter { $0 != source.ext }
        return others.count < list.count ? others + [source.ext] : others
    }

    enum Route { case image, pdfText, ffmpeg, textutil }

    static func route(_ source: Source, to ext: String) -> Route? {
        switch source.kind {
        case .pdf where ext == "txt": return .pdfText
        case .image, .pdf: return image.contains(ext) ? .image : nil
        case .video, .audio: return !ext.isEmpty && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? .ffmpeg : nil
        case .document: return document.contains(ext) ? .textutil : nil
        }
    }

    /// Whether compression controls apply: image output, or video→video.
    static func compressible(_ source: Source, to ext: String) -> Bool {
        route(source, to: ext) == .image || (source.kind == .video && video.contains(ext))
    }
}

enum Converter {
    static func destination(for url: URL, ext: String) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var out = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return out
    }

    /// `quality`: lossy image quality, or for video the target size as a fraction of the original (1 = no cap).
    /// `speed`: playback multiplier for audio/video.
    static func convert(_ source: Source, to ext: String, scale: Double, quality: Double, speed: Double = 1,
                        started: (Process) -> Void = { _ in }, progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        guard let route = Formats.route(source, to: ext) else { throw ConvertError("Can't convert .\(source.ext) to .\(ext).") }
        let out = destination(for: source.url, ext: ext)
        do {
            switch route {
            case .image:
                try imageData(source, ext: ext, scale: scale, quality: quality).write(to: out)
            case .pdfText:
                guard let text = PDFDocument(url: source.url)?.string else { throw ConvertError("This PDF has no text.") }
                try text.write(to: out, atomically: true, encoding: .utf8)
            case .textutil:
                try Tool.run(URL(fileURLWithPath: "/usr/bin/textutil"), ["-convert", ext, "-output", out.path, source.url.path])
            case .ffmpeg:
                let args = ffmpegArgs(input: source.url.path, output: out.path, ext: ext, width: source.pixels.width,
                                      scale: scale, speed: speed, videoKbps: videoKbps(source, fraction: quality, speed: speed))
                try Tool.run(Tool.find("ffmpeg"), args, started: started) { line in
                    if source.duration > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                        progress(min(1, us / 1e6 / (source.duration / speed)))
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    static func videoKbps(_ source: Source, fraction: Double, speed: Double = 1) -> Int? {
        guard fraction < 1, source.duration > 0 else { return nil }
        let totalKbps = Double(source.bytes) * fraction * 8 / (source.duration / speed) / 1000
        return max(64, Int(totalKbps) - 128) // 128k reserved for audio
    }

    static func ffmpegArgs(input: String, output: String, ext: String, width: Double, scale: Double, speed: Double = 1,
                           videoKbps: Int?) -> [String] {
        var args = ["-hide_banner", "-v", "error", "-y", "-i", input, "-progress", "pipe:1", "-nostats"]
        let retime = speed != 1 ? ["setpts=PTS/\(speed)"] : []
        let videoFilters = retime + (scale < 1 ? ["scale=trunc(iw*\(scale)/2)*2:-2"] : [])
        let audio = speed != 1 ? ["-af", "atempo=\(speed)"] : [] // atempo takes 0.5–100
        let filters = (videoFilters.isEmpty ? [] : ["-vf", videoFilters.joined(separator: ",")]) + audio
        let rate = videoKbps.map { ["-b:v", "\($0)k", "-maxrate", "\($0 * 3 / 2)k", "-bufsize", "\($0 * 2)k"] }
        switch ext {
        case "mp4", "mov", "m4v", "mkv":
            args += filters + ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p"] + (rate ?? ["-crf", "23"])
            args += ["-c:a", "aac", "-b:a", "128k"] + (ext == "mkv" ? [] : ["-movflags", "+faststart"])
        case "webm":
            args += filters + ["-c:v", "libvpx-vp9", "-row-mt", "1", "-cpu-used", "4"] + (rate ?? ["-crf", "32", "-b:v", "0"])
            args += ["-c:a", "libopus", "-b:a", "128k"]
        case "gif":
            // ponytail: capped at 800px wide and 12 fps so GIFs stay shareable; expose if someone needs more.
            let w = Int(min(width > 0 ? width * scale : 800, 800)) / 2 * 2
            let gif = retime + ["fps=12,scale=\(w):-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"]
            args += ["-vf", gif.joined(separator: ","), "-loop", "0"]
        case "mp3": args += audio + ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a", "aac": args += audio + ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "ogg": args += audio + ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case "opus": args += audio + ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "wav", "flac", "aiff": args += audio + ["-vn"]
        default: args += filters // anything else typed: let ffmpeg pick codecs for the container
        }
        return args + [output]
    }

    // MARK: Images

    static func imageData(_ source: Source, ext: String, scale: Double, quality: Double) throws -> Data {
        guard var image = loadImage(source, scale: scale) else {
            throw ConvertError("Couldn't read the image.")
        }
        if ["jpg", "bmp"].contains(ext), [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo) {
            image = flatten(image)
        }
        if ext == "webp" { return try webp(image, quality: quality) }
        guard let type = UTType(filenameExtension: ext) else { throw ConvertError("Unknown format .\(ext).") }
        return try encode(image, type: type.identifier, quality: quality)
    }

    static func loadImage(_ source: Source, scale: Double) -> CGImage? {
        if source.kind == .pdf {
            // ponytail: first page only, at 2x; render every page if multi-page export is needed.
            guard let document = PDFDocument(url: source.url), let page = document.page(at: 0) else { return nil }
            let box = page.bounds(for: .mediaBox)
            let size = CGSize(width: box.width * 2 * scale, height: box.height * 2 * scale)
            return withExtendedLifetime(document) {
                page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        }
        guard let src = CGImageSourceCreateWithURL(source.url as CFURL, nil) else { return nil }
        let side = Double(max(source.pixels.width, source.pixels.height)) * scale
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(side)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    static func encode(_ image: CGImage, type: String, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw ConvertError("Can't write \(type).")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError("Encoding failed.") }
        return data as Data
    }

    private static func flatten(_ image: CGImage) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// ImageIO can't write WebP, so hand a PNG to ffmpeg.
    private static func webp(_ image: CGImage, quality: Double) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("in.png"), out = dir.appendingPathComponent("out.webp")
        try encode(image, type: UTType.png.identifier, quality: 1).write(to: png)
        try Tool.run(Tool.find("ffmpeg"), ["-v", "error", "-y", "-i", png.path, "-c:v", "libwebp",
                                           "-quality", "\(Int(quality * 100))", out.path])
        return try Data(contentsOf: out)
    }
}

enum Tool {
    static func find(_ name: String) throws -> URL {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
            return URL(fileURLWithPath: "\(dir)/\(name)")
        }
        throw ConvertError("\(name) not found. Install it with: brew install ffmpeg")
    }

    private final class Output { var pending = "", error = Data() }

    /// Runs synchronously; call off the main thread for anything slow.
    static func run(_ exe: URL, _ args: [String], started: (Process) -> Void = { _ in },
                    line: @escaping (String) -> Void = { _ in }) throws {
        let process = Process(), out = Pipe(), err = Pipe(), buffer = Output()
        process.executableURL = exe
        process.arguments = args
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { handle in
            buffer.pending += String(decoding: handle.availableData, as: UTF8.self)
            while let newline = buffer.pending.firstIndex(of: "\n") {
                line(String(buffer.pending[..<newline]))
                buffer.pending.removeSubrange(...newline)
            }
        }
        err.fileHandleForReading.readabilityHandler = { buffer.error.append($0.availableData) }
        try process.run()
        started(process)
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if !buffer.pending.isEmpty { line(buffer.pending) }
        if process.terminationReason == .uncaughtSignal { throw ConvertError("Cancelled.") }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: buffer.error, as: UTF8.self).split(separator: "\n").last.map(String.init)
            throw ConvertError(message ?? "\(exe.lastPathComponent) failed.")
        }
    }
}
