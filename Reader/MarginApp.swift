import SwiftUI
import PencilKit
import UniformTypeIdentifiers

@main
struct MarginApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryScreen()
                .preferredColorScheme(.light)
        }
    }
}

enum InkTool: String, CaseIterable, Identifiable {
    case pen, highlight, erase

    var id: Self { self }

    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlight: "highlighter"
        case .erase: "eraser"
        }
    }

    var tool: any PKTool {
        switch self {
        case .pen: PKInkingTool(.pen, color: UIColor(red: 0.07, green: 0.27, blue: 0.62, alpha: 1), width: 3)
        case .highlight: PKInkingTool(.marker, color: UIColor(red: 1, green: 0.78, blue: 0.12, alpha: 0.36), width: 13)
        case .erase: PKEraserTool(.vector)
        }
    }
}

@MainActor
final class ReaderState: ObservableObject {
    @Published var tool: InkTool = .pen
    @Published var page = 1
    @Published var pageCount = 0
    @Published var jump: Int?
    @Published var storageError: String?
}

struct ReaderScreen: View {
    let book: LibraryBook
    let pdfURL: URL?
    let closeBook: () -> Void
    @StateObject private var reader = ReaderState()
    @State private var showingJump = false
    @State private var destination = ""

    private let paperDesk = Color(red: 0.92, green: 0.90, blue: 0.86)
    private let toolbar = Color(red: 0.98, green: 0.97, blue: 0.94)
    private let ink = Color(red: 0.11, green: 0.17, blue: 0.15)
    private let accent = Color(red: 0.12, green: 0.32, blue: 0.26)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: closeBook) {
                    Label("Library", systemImage: "chevron.backward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("back-to-library")
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .lineLimit(1)
                        .font(.system(.headline, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    ForEach(InkTool.allCases) { tool in
                        Button {
                            reader.tool = tool
                        } label: {
                            Image(systemName: tool.icon)
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 44, height: 44)
                                .foregroundStyle(reader.tool == tool ? Color.white : ink)
                                .background(reader.tool == tool ? accent : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tool.rawValue.capitalized)
                        .accessibilityAddTraits(reader.tool == tool ? [.isSelected] : [])
                    }
                }
                .padding(3)
                .background(paperDesk.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                if reader.pageCount > 0 {
                    Button {
                        destination = String(reader.page)
                        showingJump = true
                    } label: {
                        Text("\(reader.page) / \(reader.pageCount)")
                            .monospacedDigit()
                            .font(.callout.weight(.medium))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Page \(reader.page) of \(reader.pageCount). Go to page.")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .background(toolbar)
            Divider()
            BookReader(state: reader, book: book, pdfURL: pdfURL)
                .background(paperDesk)
        }
        .foregroundStyle(ink)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Go to page", isPresented: $showingJump) {
            TextField("Page number", text: $destination).keyboardType(.numberPad)
            Button("Go") {
                if let page = Int(destination), (1...reader.pageCount).contains(page) {
                    reader.jump = page
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a page from 1 to \(reader.pageCount).")
        }
        .alert("Couldn’t save your marks", isPresented: Binding(
            get: { reader.storageError != nil },
            set: { if !$0 { reader.storageError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reader.storageError ?? "")
        }
    }
}

struct BookReader: UIViewControllerRepresentable {
    @ObservedObject var state: ReaderState
    let book: LibraryBook
    let pdfURL: URL?

    func makeUIViewController(context: Context) -> BookViewController {
        BookViewController(state: state, book: book, pdfURL: pdfURL)
    }

    static func dismantleUIViewController(_ controller: BookViewController, coordinator: ()) {
        controller.flushInk()
    }

    func updateUIViewController(_ controller: BookViewController, context: Context) {
        controller.apply(tool: state.tool)
        if let page = state.jump {
            controller.go(to: page - 1)
            DispatchQueue.main.async {
                if state.jump == page { state.jump = nil }
            }
        }
    }
}

private struct LibraryScreen: View {
    @StateObject private var library = BookLibrary()
    @State private var selected: LibraryBook?
    @State private var showingFiles = false

    private let paper = Color(red: 0.98, green: 0.97, blue: 0.94)
    private let ink = Color(red: 0.11, green: 0.17, blue: 0.15)
    private let green = Color(red: 0.12, green: 0.32, blue: 0.26)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Library")
                            .font(.system(size: 43, weight: .regular, design: .serif))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button {
                            showingFiles = true
                        } label: {
                            Label("Add EPUB", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .frame(minHeight: 44)
                                .background(green, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(library.isImporting)
                    }
                    if library.isImporting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Preparing book pages…")
                                .font(.subheadline)
                        }
                        .accessibilityIdentifier("import-progress")
                    }
                    if library.books.isEmpty && !library.isImporting {
                        ContentUnavailableView("Your library starts here", systemImage: "books.vertical",
                            description: Text("Tap Add EPUB to import a DRM-free book you have permission to use. Margin creates wide margins for your Pencil notes."))
                    }
                    VStack(spacing: 0) {
                        Divider()
                        ForEach(library.books) { book in
                            Button {
                                selected = book
                            } label: {
                                bookRow(book)
                            }
                            .buttonStyle(.plain)
                            .disabled(library.isImporting)
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: 740)
                .padding(.horizontal, 25)
                .padding(.vertical, 34)
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(ink)
            .background(paper)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selected) { book in
                ReaderScreen(book: book, pdfURL: book.pdfURL(in: library.root)) {
                    selected = nil
                }
                .id(book.id)
            }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.epub]) { result in
            switch result {
            case .success(let file): open(file)
            case .failure(let error): library.importError = error.localizedDescription
            }
        }
        .onOpenURL { url in
            if url.isFileURL, url.pathExtension.lowercased() == "epub" { open(url) }
        }
        .alert("Couldn’t open the EPUB", isPresented: Binding(
            get: { library.importError != nil },
            set: { if !$0 { library.importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.importError ?? "")
        }
    }

    private func bookRow(_ book: LibraryBook) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "book.closed")
                .font(.system(size: 20, weight: .light))
                .frame(width: 48, height: 62)
                .background(green.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                if !book.author.isEmpty {
                    Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            Text("Page \(book.savedPage)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(green)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private func open(_ url: URL) {
        Task {
            if let book = await library.add(url) { selected = book }
        }
    }
}
