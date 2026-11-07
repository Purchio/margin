import Foundation
import SwiftUI
import WebKit
import PDFKit

struct LibraryBook: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let author: String

    var addedLeft: CGFloat { 0 }
    var addedRight: CGFloat { 0 }
    var savedPage: Int { max(0, UserDefaults.standard.integer(forKey: id)) + 1 }

    func pdfURL(in root: URL) -> URL? {
        return root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("Book.pdf")
    }
}

@MainActor
final class BookLibrary: ObservableObject {
    @Published private(set) var books: [LibraryBook] = []
    @Published private(set) var isImporting = false
    @Published var importError: String?
    let root: URL

    init() {
        root = URL.applicationSupportDirectory.appendingPathComponent("Library", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        books += entries.compactMap { entry in
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("Book.json")),
                  let book = try? JSONDecoder().decode(LibraryBook.self, from: data),
                  book.id == entry.lastPathComponent,
                  FileManager.default.fileExists(atPath: entry.appendingPathComponent("Book.pdf").path) else { return nil }
            return book
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func add(_ url: URL) async -> LibraryBook? {
        guard !isImporting else { return nil }
        isImporting = true
        defer { isImporting = false }
        let stage = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        do {
            let source = try await Task.detached(priority: .userInitiated) { try EPUBSource(url: url) }.value
            let id = "epub-\(source.digest)"
            if let existing = books.first(where: { $0.id == id }) { return existing }

            let input = stage.appendingPathComponent("Source", isDirectory: true)
            let result = stage.appendingPathComponent("Result", isDirectory: true)
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
            let fallback = url.deletingPathExtension().lastPathComponent
            let prepared = try await Task.detached(priority: .userInitiated) {
                try source.prepare(in: input, fallbackTitle: fallback)
            }.value
            let pdf = result.appendingPathComponent("Book.pdf")
            try await BookPrinter().render(prepared.htmlURL, to: pdf)
            let book = LibraryBook(id: id, title: prepared.title, author: prepared.author)
            try JSONEncoder().encode(book).write(to: result.appendingPathComponent("Book.json"), options: .atomic)
            try FileManager.default.moveItem(at: result, to: root.appendingPathComponent(id, isDirectory: true))
            books.append(book)
            return book
        } catch {
            importError = error.localizedDescription
            return nil
        }
    }
}

@MainActor
private final class BookPrinter: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Error>?
    private var sourceURL: URL?
    private var timeout: Task<Void, Never>?

    func render(_ source: URL, to output: URL) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 680), configuration: configuration)
        web.navigationDelegate = self

        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        if let window = windows.first(where: \.isKeyWindow) {
            // Keep WebKit in the view hierarchy while it lays out the print view.
            web.isUserInteractionEnabled = false
            web.accessibilityElementsHidden = true
            window.insertSubview(web, at: 0)
        }
        defer {
            web.stopLoading()
            web.removeFromSuperview()
            timeout?.cancel()
        }

        sourceURL = source
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            web.loadFileURL(source, allowingReadAccessTo: source.deletingLastPathComponent())
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                if !Task.isCancelled { self?.complete(.failure(EPUBError.noPages)) }
            }
        }
        let printer = WidePageRenderer()
        let formatter = web.viewPrintFormatter()
        formatter.contentInsets = .zero
        printer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let count = printer.numberOfPages
        guard count > 0 else { throw EPUBError.noPages }
        guard count <= 2200 else { throw EPUBError.tooLarge }
        printer.prepare(forDrawingPages: NSRange(location: 0, length: count))

        try UIGraphicsPDFRenderer(bounds: printer.paperRect).writePDF(to: output) { context in
            for index in 0..<count {
                autoreleasepool {
                    context.beginPage()
                    printer.drawPage(at: index, in: printer.paperRect)
                }
            }
        }
        guard let document = PDFDocument(url: output), document.pageCount == count,
              (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > count * 850 else {
            throw EPUBError.noPages
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.standardizedFileURL == sourceURL?.standardizedFileURL ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        complete(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<Void, Error>) {
        loaded?.resume(with: result)
        loaded = nil
    }
}

@MainActor
private final class WidePageRenderer: UIPrintPageRenderer {
    override var paperRect: CGRect { CGRect(x: 0, y: 0, width: 770, height: 900) }
    override var printableRect: CGRect { paperRect.insetBy(dx: 175, dy: 58) }

    override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
        let number = "\(pageIndex + 1)" as NSString
        let style: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let size = number.size(withAttributes: style)
        number.draw(at: CGPoint(x: paperRect.midX - size.width / 2, y: paperRect.maxY - 34), withAttributes: style)
    }

    override init() {
        super.init()
        footerHeight = 20
    }
}
