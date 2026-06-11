import Foundation

/// Filename slug for a user-entered recording title: diacritics folded ("café" → "cafe"),
/// lowercased, every run of non-alphanumerics collapsed to a single hyphen, trimmed, and
/// hard-capped at `maxLength` (trailing hyphen dropped). Returns "" if nothing survives.
public func slugify(_ title: String, maxLength: Int = 60) -> String {
    let folded = title
        .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()
    var slug = ""
    for scalar in folded.unicodeScalars {
        switch scalar {
        case "a"..."z", "0"..."9":
            slug.unicodeScalars.append(scalar)
        default:
            if !slug.isEmpty && !slug.hasSuffix("-") { slug.append("-") }
        }
    }
    while slug.hasSuffix("-") { slug.removeLast() }
    if slug.count > maxLength {
        slug = String(slug.prefix(maxLength))
        while slug.hasSuffix("-") { slug.removeLast() }
    }
    return slug
}

/// Filename stem (no extension) for a recording: `YYYY-MM-DD-<slug>` when the title
/// slugs to something usable, else the full timestamp stamp (today's behaviour).
/// `stamp` is the `yyyy-MM-dd_HH-mm-ss` recording stamp.
public func transcriptStem(stamp: String, title: String?) -> String {
    let slug = slugify(title ?? "")
    guard !slug.isEmpty else { return stamp }
    return "\(stamp.prefix(10))-\(slug)"
}

/// First non-colliding `<stem>.md` in `dir`: `stem.md`, then `stem-2.md`, `stem-3.md`, …
/// `exists` is injectable for tests; defaults to the real filesystem.
public func availableTranscriptURL(in dir: URL, stem: String,
                                   exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
    var url = dir.appendingPathComponent("\(stem).md")
    var n = 2
    while exists(url) {
        url = dir.appendingPathComponent("\(stem)-\(n).md")
        n += 1
    }
    return url
}
