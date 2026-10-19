import AppKit

/// `Into --self-test`: converts generated samples through every route and checks the output.
enum SelfTest {
    static func run() -> Int32 {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("into-selftest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "ok   " : "FAIL ", what)
            if !ok { failures += 1 }
        }
        func convert(_ source: Source, _ ext: String, scale: Double = 1, quality: Double = 0.85) {
            do {
                let out = try Converter.convert(source, to: ext, scale: scale, quality: quality)
                let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                check(size > 0 && out.deletingLastPathComponent().path == dir.path, "\(source.ext) → \(out.lastPathComponent) (\(size) B)")
            } catch {
                check(false, "\(source.ext) → \(ext): \(error.localizedDescription)")
            }
        }

        // Image with transparency, so the JPEG flatten path runs.
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.3, blue: 0, alpha: 0.6))
        ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 360, height: 260))
        let png = dir.appendingPathComponent("pic.png")
        try! Converter.encode(ctx.makeImage()!, type: "public.png", quality: 1).write(to: png)
        let image = Source(url: png)!
        check(image.kind == .image && image.pixels == CGSize(width: 400, height: 300), "png probed as 400×300 image")
        check(Formats.suggestions(for: image).last == "png", "own format suggested last")
        for ext in Formats.image { convert(image, ext) }
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pic 2.png").path), "existing name gets ' 2'")
        let full = try! Converter.imageData(image, ext: "jpg", scale: 1, quality: 0.85).count
        let half = try! Converter.imageData(image, ext: "jpg", scale: 0.5, quality: 0.85).count
        check(half < full, "50% scale is smaller (\(half) < \(full))")

        let pdf = Source(url: dir.appendingPathComponent("pic.pdf"))!
        check(pdf.kind == .pdf, "pdf probed")
        convert(pdf, "png")

        let txt = dir.appendingPathComponent("note.txt")
        try! "hello into".write(to: txt, atomically: true, encoding: .utf8)
        let doc = Source(url: txt)!
        for ext in ["docx", "html", "rtf"] { convert(doc, ext) }

        if let ffmpeg = try? Tool.find("ffmpeg") {
            let mp4 = dir.appendingPathComponent("clip.mp4")
            try! Tool.run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=15",
                                   "-f", "lavfi", "-i", "sine=duration=2", "-shortest", "-pix_fmt", "yuv420p", mp4.path])
            let video = Source(url: mp4)!
            check(video.kind == .video && video.duration > 1.5 && video.pixels.width == 320, "mp4 probed: \(video.summary)")
            for ext in ["mov", "webm", "gif", "mp3"] { convert(video, ext) }
            convert(video, "mp4", scale: 0.5, quality: 0.5)
            for ext in ["mp4", "mp3"] { // gif shares the same setpts filter
                let fast = (try? Converter.convert(video, to: ext, scale: 1, quality: 1, speed: 2)).flatMap(Source.init(url:))
                let seconds = fast?.duration ?? 0
                check(abs(seconds - video.duration / 2) < 0.3, "2× \(ext) lasts \(seconds)s (from \(video.duration)s)")
            }
            check(Formats.route(video, to: "flv") == .ffmpeg && Formats.route(video, to: "../x") == nil, "typed formats sanitized")
        } else {
            print("skip  ffmpeg not installed")
        }
        print(failures == 0 ? "all passed" : "\(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
