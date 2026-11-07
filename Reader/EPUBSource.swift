import Foundation
import CryptoKit
import zlib

#if canImport(FoundationXML)
import FoundationXML
#endif

enum EPUBError: LocalizedError {
    case invalid, protected, tooLarge, noPages, cannotRead

    var errorDescription: String? {
        switch self {
        case .invalid: "This file isn’t a readable EPUB."
        case .protected: "This EPUB is protected. Choose a DRM-free EPUB."
        case .tooLarge: "This EPUB is too large for Margin to prepare."
        case .noPages: "Margin couldn’t lay out any pages in this EPUB."
        case .cannotRead: "Files couldn’t make this EPUB available. Download it and try again."
        }
    }
}

struct EPUBSource {
    let bytes: Data
    let digest: String

    init(url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
            result = Result {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 160 * 1024 * 1024 else { throw EPUBError.tooLarge }
                return try Data(contentsOf: file)
            }
        }
        guard let result, coordinationError == nil else { throw EPUBError.cannotRead }
        bytes = try result.get()
        guard bytes.count <= 160 * 1024 * 1024 else { throw EPUBError.tooLarge }
        digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    struct Prepared {
        let title: String
        let author: String
        let htmlURL: URL
    }

    func prepare(in directory: URL, fallbackTitle: String) throws -> Prepared {
        let zip = try EPUBZip(bytes)
        if zip.contains("META-INF/encryption.xml") {
            let encryption = try EPUBPackage.read(zip.read("META-INF/encryption.xml"))
            let fontAlgorithms: Set<String> = [
                "http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"
            ]
            if encryption.algorithms.isEmpty || encryption.algorithms.contains(where: { !fontAlgorithms.contains($0) }) {
                throw EPUBError.protected
            }
        }
        let container = try EPUBPackage.read(zip.read("META-INF/container.xml"))
        guard let path = container.rootfile else { throw EPUBError.invalid }
        let package = try EPUBPackage.read(zip.read(path))
        guard !package.spine.isEmpty else { throw EPUBError.noPages }
        let title = package.title.isEmpty ? fallbackTitle : package.title
        let chapters = try package.spine.map { id in
            guard let item = package.items[id], let path = Self.resolve(item.href, from: path) else {
                throw EPUBError.invalid
            }
            return path
        }
        let allowedItems = Set(package.items.values.compactMap { item -> String? in
            let media = item.media
            guard media.hasPrefix("image/") || media.hasPrefix("font/") ||
                    media == "text/css" || media.contains("font") else { return nil }
            return Self.resolve(item.href, from: path)
        })
        var bytesWritten = 0
        for item in allowedItems where zip.contains(item) {
            let data = try zip.read(item)
            bytesWritten += data.count
            guard bytesWritten <= 360 * 1024 * 1024 else { throw EPUBError.tooLarge }
            let target = directory.appendingPathComponent(item)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }

        let bodyPattern = try NSRegularExpression(pattern: #"(?is)<body\b([^>]*)>(.*?)</body\s*>"#)
        let linkPattern = try NSRegularExpression(pattern: #"(?is)<link\b[^>]*>"#)
        let sourcePattern = try NSRegularExpression(pattern: #"(?i)(\b(?:src|href)\s*=\s*)(["'])(.*?)\2"#)
        let attributePattern = try NSRegularExpression(pattern: #"(?i)\b(href|rel|class)\s*=\s*(["'])(.*?)\2"#)
        let paths = Dictionary(chapters.enumerated().map { ($1, "spine-\($0)") }, uniquingKeysWith: { first, _ in first })
        var stylePaths: [String] = []
        var sections: [String] = []
        var chapterBytes = 0

        for (index, chapter) in chapters.enumerated() {
            let chapterData = try zip.read(chapter)
            chapterBytes += chapterData.count
            guard chapterBytes <= 28 * 1024 * 1024 else { throw EPUBError.tooLarge }
            guard let markup = String(data: chapterData, encoding: .utf8) ??
                    String(data: chapterData, encoding: .utf16),
                  let match = bodyPattern.firstMatch(in: markup, range: NSRange(markup.startIndex..., in: markup)),
                  let bodyRange = Range(match.range(at: 2), in: markup),
                  let attributeRange = Range(match.range(at: 1), in: markup) else { throw EPUBError.invalid }
            for tag in linkPattern.matches(in: markup, range: NSRange(markup.startIndex..., in: markup)) {
                guard let tagRange = Range(tag.range, in: markup) else { continue }
                let attrs = Self.attributes(String(markup[tagRange]), using: attributePattern)
                if attrs["rel"]?.lowercased() == "stylesheet", let href = attrs["href"],
                   let style = Self.resolve(href, from: chapter), allowedItems.contains(style), !stylePaths.contains(style) {
                    stylePaths.append(style)
                }
            }

            var body = String(markup[bodyRange])
            let original = body
            let replacements: [(NSRange, String)] = sourcePattern.matches(in: original, range: NSRange(original.startIndex..., in: original)).compactMap { match in
                guard let range = Range(match.range(at: 3), in: original) else { return nil }
                let value = String(original[range])
                guard !value.hasPrefix("#"), !value.hasPrefix("data:") else { return nil }
                guard let member = Self.resolve(value, from: chapter) else { return (match.range(at: 3), "#") }
                if let anchor = paths[member] { return (match.range(at: 3), "#\(anchor)") }
                return (match.range(at: 3), Self.urlPath(member))
            }
            let buffer = NSMutableString(string: body)
            for (range, value) in replacements.reversed() { buffer.replaceCharacters(in: range, with: value) }
            body = buffer as String
            let cls = Self.attributes(String(markup[attributeRange]), using: attributePattern)["class"] ?? ""
            sections.append("<section id=\"spine-\(index)\" class=\"margin-section \(Self.escape(cls))\">\(body)</section>")
        }

        let css = stylePaths.map { "<link rel=\"stylesheet\" href=\"\(Self.urlPath($0))\">" }.joined()
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src file: 'unsafe-inline'; img-src file: data:; font-src file: data:; base-uri 'none'; form-action 'none'">
        <title>\(Self.escape(title))</title>\(css)
        <style>
        @page { margin: 0; }
        html, body { background: white !important; width: auto !important; height: auto !important; margin: 0 !important; padding: 0 !important; }
        body { color: #25211d !important; font: 18px/1.48 Georgia, serif; }
        .margin-section { display: block; width: 100% !important; }
        .margin-section + .margin-section { break-before: page; page-break-before: always; }
        .margin-section :is(img,svg) { max-width: 100% !important; max-height: 630px; height: auto !important; }
        .margin-section :is(h1,h2,h3) { break-after: avoid; page-break-after: avoid; }
        </style></head><body>\(sections.joined())</body></html>
        """
        let output = directory.appendingPathComponent("__margin_book__.html")
        try html.write(to: output, atomically: true, encoding: .utf8)
        return Prepared(title: title, author: package.author, htmlURL: output)
    }

    fileprivate static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }

    private static func resolve(_ href: String, from file: String) -> String? {
        guard let parts = URLComponents(string: href), parts.scheme == nil, parts.host == nil,
              !parts.path.hasPrefix("/"), !parts.path.isEmpty, !parts.path.contains("\\") else { return nil }
        var segments = file.split(separator: "/").dropLast().map(String.init)
        for part in parts.path.split(separator: "/") {
            if part == ".." {
                guard !segments.isEmpty else { return nil }
                segments.removeLast()
            } else if part != "." { segments.append(String(part)) }
        }
        let path = segments.joined(separator: "/")
        return safePath(path) ? path : nil
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func urlPath(_ path: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-._~"))
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func attributes(_ markup: String, using regex: NSRegularExpression) -> [String: String] {
        var result: [String: String] = [:]
        for item in regex.matches(in: markup, range: NSRange(markup.startIndex..., in: markup)) {
            guard let key = Range(item.range(at: 1), in: markup), let value = Range(item.range(at: 3), in: markup) else { continue }
            result[String(markup[key]).lowercased()] = String(markup[value])
        }
        return result
    }
}

private final class EPUBPackage: NSObject, XMLParserDelegate {
    struct Item {
        let href: String
        let media: String
    }

    var rootfile: String?
    var items: [String: Item] = [:]
    var spine: [String] = []
    var title = ""
    var author = ""
    var algorithms: [String] = []
    private var field: String?
    private var value = ""

    static func read(_ data: Data) throws -> EPUBPackage {
        let result = EPUBPackage()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = result
        guard parser.parse() else { throw EPUBError.invalid }
        return result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch name {
        case "rootfile":
            if rootfile == nil { rootfile = attributes["full-path"] }
        case "item":
            if let id = attributes["id"], let href = attributes["href"], let media = attributes["media-type"] {
                items[id] = Item(href: href, media: media)
            }
        case "itemref":
            if let id = attributes["idref"] { spine.append(id) }
        case "EncryptionMethod":
            if let algorithm = attributes["Algorithm"] { algorithms.append(algorithm) }
        case "title", "creator":
            field = name
            value = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == field else { return }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "title", title.isEmpty { title = value }
        if name == "creator", author.isEmpty { author = value }
        field = nil
    }
}

private struct EPUBZip {
    private struct Entry {
        let offset: Int
        let compressedSize: Int
        let size: Int
        let method: UInt16
        let flags: UInt16
        let crc: UInt32
    }

    private let bytes: Data
    private let entries: [String: Entry]

    init(_ bytes: Data) throws {
        self.bytes = bytes
        var entries: [String: Entry] = [:]
        guard bytes.count >= 22,
              let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1).first(where: {
                  bytes.u32($0) == 0x06054b50 && $0 + 22 + Int(bytes.u16($0 + 20)) == bytes.count
              }),
              bytes.u16(end + 4) == 0, bytes.u16(end + 6) == 0,
              bytes.u16(end + 8) == bytes.u16(end + 10) else { throw EPUBError.invalid }
        let count = Int(bytes.u16(end + 10))
        var cursor = Int(bytes.u32(end + 16))
        let directoryEnd = cursor + Int(bytes.u32(end + 12))
        guard directoryEnd <= end, count > 0, count < 20_000 else { throw EPUBError.invalid }
        for _ in 0..<count {
            guard cursor + 46 <= directoryEnd, bytes.u32(cursor) == 0x02014b50 else { throw EPUBError.invalid }
            let nameEnd = cursor + 46 + Int(bytes.u16(cursor + 28))
            let next = nameEnd + Int(bytes.u16(cursor + 30)) + Int(bytes.u16(cursor + 32))
            guard next <= directoryEnd, let name = String(data: bytes[cursor + 46..<nameEnd], encoding: .utf8) else {
                throw EPUBError.invalid
            }
            if !name.hasSuffix("/") {
                guard EPUBSource.safePath(name), entries[name] == nil else { throw EPUBError.invalid }
                entries[name] = Entry(offset: Int(bytes.u32(cursor + 42)), compressedSize: Int(bytes.u32(cursor + 20)),
                                      size: Int(bytes.u32(cursor + 24)), method: bytes.u16(cursor + 10),
                                      flags: bytes.u16(cursor + 8), crc: bytes.u32(cursor + 16))
            }
            cursor = next
        }
        self.entries = entries
    }

    func contains(_ path: String) -> Bool { entries[path] != nil }

    func read(_ path: String) throws -> Data {
        guard let entry = entries[path], entry.offset + 30 <= bytes.count,
              bytes.u32(entry.offset) == 0x04034b50 else { throw EPUBError.invalid }
        guard entry.flags & 1 == 0 else { throw EPUBError.protected }
        guard entry.size <= 80 * 1024 * 1024 else { throw EPUBError.tooLarge }
        let start = entry.offset + 30 + Int(bytes.u16(entry.offset + 26)) + Int(bytes.u16(entry.offset + 28))
        guard start + entry.compressedSize <= bytes.count else { throw EPUBError.invalid }
        let compressed = bytes[start..<start + entry.compressedSize]
        let data: Data
        switch entry.method {
        case 0: data = compressed
        case 8: data = try Self.inflate(compressed, size: entry.size)
        default: throw EPUBError.invalid
        }
        let checksum = data.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
        guard data.count == entry.size, checksum == entry.crc else { throw EPUBError.invalid }
        return data
    }

    private static func inflate(_ compressed: Data, size: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw EPUBError.invalid
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: max(1, size))
        let capacity = output.count
        let status = compressed.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { result in
                stream.next_in = input.bindMemory(to: Bytef.self).baseAddress.map { UnsafeMutablePointer(mutating: $0) }
                stream.avail_in = uInt(compressed.count)
                stream.next_out = result.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size else { throw EPUBError.invalid }
        if size == 0 { output.removeAll() }
        return output
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }
}
