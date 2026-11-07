import UIKit
import PencilKit
import CoreGraphics

@MainActor
final class BookViewController: UIViewController, UIScrollViewDelegate, PKCanvasViewDelegate {
    private let state: ReaderState
    private let scroll = UIScrollView()
    private let bookSurface = UIView()
    private let pageGap: CGFloat = 18
    private let sideRoom: CGFloat = 16
    private let book: LibraryBook
    private let pdfURL: URL?
    private var positionKey: String { book.id }
    private var document: CGPDFDocument?
    private var pageSize: CGSize = .zero
    private var views: [Int: BookPageView] = [:]
    private var lastSize: CGSize = .zero
    private var fitScale: CGFloat = 1
    private var isLayingOut = false
    private var currentPage = 0
    private var chosenTool: InkTool = .pen
    private var store: InkStore?
    private var dirty: [Int: PKDrawing] = [:]
    private var saveWork: DispatchWorkItem?
    private var writeErrorShown = false

    private var pageCount: Int { document?.numberOfPages ?? 0 }
    private var stride: CGFloat { pageSize.height + pageGap }

    init(state: ReaderState, book: LibraryBook, pdfURL: URL?) {
        self.state = state
        self.book = book
        self.pdfURL = pdfURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.92, green: 0.90, blue: 0.86, alpha: 1)

        guard let url = pdfURL,
              let pdf = CGPDFDocument(url as CFURL),
              let first = pdf.page(at: 1), pdf.numberOfPages > 0 else {
            showLoadError()
            return
        }
        document = pdf
        let originalSize = first.getBoxRect(.mediaBox).size
        pageSize = CGSize(width: originalSize.width + book.addedLeft + book.addedRight, height: originalSize.height)
        do {
            store = try InkStore(bookID: positionKey)
        } catch {
            DispatchQueue.main.async {
                self.state.storageError = error.localizedDescription
            }
        }

        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        scroll.delaysContentTouches = false
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        scroll.panGestureRecognizer.allowedTouchTypes = [finger]
        scroll.pinchGestureRecognizer?.allowedTouchTypes = [finger]
        view.addSubview(scroll)

        bookSurface.frame = CGRect(x: 0, y: 0, width: pageSize.width,
                                  height: pageGap + CGFloat(pageCount) * stride)
        scroll.addSubview(bookSurface)
        scroll.contentSize = bookSurface.bounds.size
        currentPage = min(max(0, UserDefaults.standard.integer(forKey: positionKey)), pageCount - 1)
        DispatchQueue.main.async {
            self.state.pageCount = self.pageCount
            self.state.page = self.currentPage + 1
        }
        NotificationCenter.default.addObserver(self, selector: #selector(flushInk),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        flushInk()
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = scroll.bounds.size
        guard document != nil, size.width > sideRoom * 2, size.height > 0, size != lastSize else { return }
        let firstLayout = lastSize == .zero
        let priorScale = scroll.zoomScale
        let oldCenter = (scroll.contentOffset.y + lastSize.height / 2) / priorScale
        let oldHorizontalCenter = (scroll.contentOffset.x + lastSize.width / 2) / priorScale
        let zoomRatio = priorScale / fitScale
        lastSize = size
        isLayingOut = true

        fitScale = min(820, size.width - sideRoom * 2) / pageSize.width
        scroll.minimumZoomScale = fitScale
        scroll.maximumZoomScale = max(fitScale * 3.5, priorScale)
        scroll.setZoomScale(firstLayout ? fitScale : fitScale * max(1, min(3.5, zoomRatio)), animated: false)
        scroll.maximumZoomScale = fitScale * 3.5
        updateInsets()

        if firstLayout {
            setOffset(forPage: currentPage)
        } else {
            let x = oldHorizontalCenter * scroll.zoomScale - size.width / 2
            let y = oldCenter * scroll.zoomScale - size.height / 2
            scroll.contentOffset = boundedOffset(x: x, y: y)
        }
        isLayingOut = false
        updateVisiblePages()
    }

    func apply(tool: InkTool) {
        guard chosenTool != tool else { return }
        chosenTool = tool
        for page in views.values { page.canvas.tool = tool.tool }
    }

    func go(to index: Int) {
        guard (0..<pageCount).contains(index), lastSize != .zero else { return }
        setOffset(forPage: index)
        updateVisiblePages()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { bookSurface }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateInsets()
        if !isLayingOut { updateVisiblePages() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !isLayingOut { updateVisiblePages() }
    }

    private func updateInsets() {
        let horizontal = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
        if abs(scroll.contentInset.left - horizontal) > 0.25 {
            scroll.contentInset = UIEdgeInsets(top: 0, left: horizontal, bottom: 0, right: horizontal)
        }
    }

    private func boundedOffset(x: CGFloat, y: CGFloat) -> CGPoint {
        let inset = scroll.contentInset
        let maxX = max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)
        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
        return CGPoint(x: min(maxX, max(-inset.left, x)), y: min(maxY, max(0, y)))
    }

    private func setOffset(forPage index: Int) {
        let y = (pageGap + CGFloat(index) * stride) * scroll.zoomScale - 10
        scroll.contentOffset = boundedOffset(x: scroll.contentOffset.x, y: y)
    }

    private func updateVisiblePages() {
        guard let document, lastSize != .zero else { return }
        let scale = scroll.zoomScale
        let top = max(0, scroll.contentOffset.y / scale)
        let bottom = (scroll.contentOffset.y + scroll.bounds.height) / scale
        let lower = max(0, min(pageCount - 1, Int((top - pageGap) / stride) - 1))
        let upper = max(lower, min(pageCount - 1, Int((bottom - pageGap) / stride) + 1))

        for index in Array(views.keys) where !(lower...upper).contains(index) {
            views.removeValue(forKey: index)?.removeFromSuperview()
        }
        for index in lower...upper where views[index] == nil {
            guard let page = document.page(at: index + 1) else { continue }
            let frame = CGRect(x: 0, y: pageGap + CGFloat(index) * stride,
                               width: pageSize.width, height: pageSize.height)
            let view = BookPageView(frame: frame, page: page, left: book.addedLeft, right: book.addedRight)
            view.canvas.tag = index
            view.canvas.tool = chosenTool.tool
            if let drawing = dirty[index] {
                view.canvas.drawing = drawing
            } else if let drawing = store?.load(page: index) {
                view.canvas.drawing = drawing.transformed(using: CGAffineTransform(translationX: book.addedLeft, y: 0))
            }
            view.canvas.delegate = self
            bookSurface.addSubview(view)
            views[index] = view
        }
        let readingY = top + min(100, max(0, bottom - top) * 0.2)
        let page = max(0, min(pageCount - 1, Int((readingY - pageGap) / stride)))
        if currentPage != page {
            currentPage = page
            UserDefaults.standard.set(page, forKey: positionKey)
            DispatchQueue.main.async { self.state.page = self.currentPage + 1 }
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        dirty[canvasView.tag] = canvasView.drawing
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushInk() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        if dirty[canvasView.tag] != nil { flushInk() }
    }

    @objc func flushInk() {
        saveWork?.cancel()
        saveWork = nil
        guard let store, !dirty.isEmpty else { return }
        for (page, drawing) in Array(dirty) {
            do {
                try store.save(drawing.transformed(using: CGAffineTransform(translationX: -book.addedLeft, y: 0)), page: page)
                dirty.removeValue(forKey: page)
            } catch {
                if !writeErrorShown {
                    writeErrorShown = true
                    state.storageError = "Your current marks are still open. Free up storage and try drawing again."
                }
            }
        }
        if dirty.isEmpty { writeErrorShown = false }
    }

    private func showLoadError() {
        let label = UILabel()
        label.text = "The book couldn’t be opened."
        label.textAlignment = .center
        label.frame = view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
}

private final class BookPageView: UIView {
    let canvas = PKCanvasView()

    init(frame: CGRect, page: CGPDFPage, left: CGFloat, right: CGFloat) {
        super.init(frame: frame)
        backgroundColor = .white
        layer.borderWidth = 0.5
        layer.borderColor = UIColor(white: 0, alpha: 0.12).cgColor

        let paperFrame = CGRect(x: left, y: 0, width: bounds.width - left - right, height: bounds.height)
        let paper = PrintedPage(frame: paperFrame, page: page)
        addSubview(paper)
        canvas.frame = bounds
        canvas.isOpaque = false
        canvas.backgroundColor = .clear
        canvas.drawingPolicy = .pencilOnly
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = false
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { nil }
}

private final class PrintedPage: UIView {
    private let page: CGPDFPage

    init(frame: CGRect, page: CGPDFPage) {
        self.page = page
        super.init(frame: frame)
        backgroundColor = .white
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        context.restoreGState()
    }
}

private struct InkStore {
    private let folder: URL

    init(bookID: String) throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        folder = root.appendingPathComponent(bookID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func load(page: Int) -> PKDrawing? {
        guard let data = try? Data(contentsOf: location(page)) else { return nil }
        return try? PKDrawing(data: data)
    }

    func save(_ drawing: PKDrawing, page: Int) throws {
        try drawing.dataRepresentation().write(to: location(page), options: .atomic)
    }

    private func location(_ page: Int) -> URL {
        folder.appendingPathComponent("\(page).drawing")
    }
}
