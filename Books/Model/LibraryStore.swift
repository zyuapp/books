import AppKit
import CryptoKit
import Foundation
import Observation
import PDFKit

struct BookRecord: Identifiable, Hashable {
    let id: String
    var url: URL
    var format: BookFormat
    var fileSize: Int
    var inCloudLibrary: Bool
    var isDownloaded: Bool
    var fileDate: Date
}

/// The library folder (see `LibraryLocation`). Book files sit anywhere inside it;
/// per-book state and cover thumbnails sync in `Reading Data/`.
@MainActor @Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var books: [BookRecord] = []
    private(set) var states: [String: ReadingState] = [:]
    private(set) var coverVersion = 0
    private(set) var isScanning = false
    @ObservationIgnored private var located = false
    @ObservationIgnored private var statesLoaded = false
    /// The library folder has been scanned at least once since it was opened.
    private(set) var scannedOnce = false
    var lastError: String?

    private(set) var rootURL = LibraryLocation.localRoot
    private(set) var usesICloud = false
    var dataURL: URL { rootURL.appendingPathComponent("Reading Data", isDirectory: true) }
    var coversURL: URL { dataURL.appendingPathComponent("Covers", isDirectory: true) }

    @ObservationIgnored private var covers: [String: NSImage] = [:]
    @ObservationIgnored private var pendingSaves: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var metadataQueue: Set<String> = []
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Bumped when the library folder changes, so work started for the old folder is dropped.
    @ObservationIgnored private var generation = 0

    private static let recentsKey = "externalBookPaths"

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locate() }
        }
        locate()
    }

    /// Picks the library folder and switches to it if it changed.
    private func locate() {
        Task {
            let cloud = await Task.detached(priority: .userInitiated) { LibraryLocation.iCloudRoot() }.value
            let root = cloud ?? LibraryLocation.localRoot
            guard !located || root != rootURL else { return }
            open(root, cloud: cloud != nil)
        }
    }

    private func open(_ root: URL, cloud: Bool) {
        flushAll()
        generation += 1
        watcher = nil
        rescanTask?.cancel()
        rootURL = root
        usesICloud = cloud
        books = []
        states = [:]
        covers = [:]
        coverVersion += 1
        statesLoaded = false
        scannedOnce = false
        located = true
        try? FileManager.default.createDirectory(at: coversURL, withIntermediateDirectories: true)
        SyncedSettings.shared.attach(to: dataURL)
        reloadStates()
        scan()
        watcher = DirectoryWatcher(url: rootURL) { [weak self] paths in
            Task { @MainActor in self?.filesChanged(paths) }
        }
    }

    /// Waits for the library folder, then (briefly) for the first state load and scan, so lookups don't miss existing books.
    func waitUntilReady() async {
        start()
        while !located { try? await Task.sleep(for: .milliseconds(50)) }
        for _ in 0..<60 where !(statesLoaded && scannedOnce) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func isInLibrary(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path + "/")
    }

    // MARK: Identity

    nonisolated static func bookID(fileName: String, size: Int) -> String {
        let digest = SHA256.hash(data: Data("\(fileName.lowercased())|\(size)".utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func bookID(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return bookID(fileName: url.lastPathComponent, size: size)
    }

    // MARK: Scanning

    func scan() {
        isScanning = true
        let root = rootURL
        let data = dataURL
        let externals = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        let gen = generation
        Task.detached(priority: .utility) {
            var found: [BookRecord] = []
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                          .ubiquitousItemDownloadingStatusKey, .isPackageKey]
            if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in e {
                    if url.path == data.path || url.path.hasPrefix(data.path + "/") { e.skipDescendants(); continue }
                    if let r = Self.record(url, inCloud: true) { found.append(r) }
                }
            }
            for path in externals {
                let url = URL(fileURLWithPath: path)
                if !url.path.hasPrefix(root.path + "/"), let r = Self.record(url, inCloud: false) { found.append(r) }
            }
            var seen = Set<String>()
            let unique = found.filter { seen.insert($0.id).inserted }
            await MainActor.run {
                guard gen == self.generation else { return }
                self.books = unique
                self.isScanning = false
                self.scannedOnce = true
                self.ensureStatesAndMetadata()
            }
        }
    }

    nonisolated private static func record(_ url: URL, inCloud: Bool) -> BookRecord? {
        guard let format = BookFormat(url: url) else { return nil }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                                       .ubiquitousItemDownloadingStatusKey, .isPackageKey])
        guard values?.isRegularFile == true || values?.isPackage == true else { return nil }
        let size = values?.fileSize ?? 0
        let status = values?.ubiquitousItemDownloadingStatus
        return BookRecord(
            id: bookID(fileName: url.lastPathComponent, size: size), url: url, format: format, fileSize: size,
            inCloudLibrary: inCloud, isDownloaded: status == nil || status == .current || status == .downloaded,
            fileDate: values?.contentModificationDate ?? Date()
        )
    }

    private func filesChanged(_ paths: [String]) {
        let dataPrefix = dataURL.path + "/"
        let changedStates = paths.filter { $0.hasPrefix(dataPrefix) && $0.hasSuffix(".json") && !$0.hasPrefix(coversURL.path + "/") }
        let coverChanged = paths.contains { $0.hasPrefix(coversURL.path + "/") }
        let booksChanged = paths.contains { !$0.hasPrefix(dataPrefix) && $0 != dataURL.path }
        if !changedStates.isEmpty { reloadStates(Set(changedStates).map { URL(fileURLWithPath: $0) }) }
        if coverChanged { covers.removeAll(); coverVersion += 1 }
        if paths.contains(where: SyncedSettings.shared.isSettingsFile) { SyncedSettings.shared.sync() }
        if booksChanged {
            rescanTask?.cancel()
            rescanTask = Task {
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { scan() }
            }
        }
    }

    private func ensureStatesAndMetadata() {
        for book in books {
            if states[book.id] == nil {
                var s = ReadingState(bookID: book.id, fileName: book.url.lastPathComponent)
                s.format = book.format
                s.added = book.fileDate
                states[book.id] = s
            }
            let needsMeta = states[book.id]?.title == nil || !FileManager.default.fileExists(atPath: coverFile(book.id).path)
            if needsMeta && book.isDownloaded { extractMetadata(book) }
        }
    }

    private func extractMetadata(_ book: BookRecord) {
        guard metadataQueue.insert(book.id).inserted else { return }
        let coverURL = coverFile(book.id)
        let needsCover = !FileManager.default.fileExists(atPath: coverURL.path)
        let gen = generation
        Task.detached(priority: .utility) {
            let meta = BookMetadata.extract(book.url, id: book.id, wantCover: needsCover)
            if let jpeg = meta.coverJPEG { try? jpeg.write(to: coverURL, options: .atomic) }
            await MainActor.run {
                self.metadataQueue.remove(book.id)
                guard gen == self.generation else { return }
                self.update(book.id) { s in
                    s.title = s.title ?? meta.title
                    s.author = s.author ?? meta.author
                    s.format = book.format
                }
                if meta.coverJPEG != nil {
                    self.covers[book.id] = nil
                    self.coverVersion += 1
                }
            }
        }
    }

    // MARK: State

    private func stateFile(_ id: String) -> URL { dataURL.appendingPathComponent("\(id).json") }
    func coverFile(_ id: String) -> URL { coversURL.appendingPathComponent("\(id).jpg") }

    /// Loads state files (all of them, or just the changed ones) and merges iCloud conflict copies.
    private func reloadStates(_ only: [URL]? = nil) {
        let dir = dataURL
        let gen = generation
        Task.detached(priority: .userInitiated) {
            let files = only ?? ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            var loaded: [String: ReadingState] = [:]
            var conflicts: [URL] = []
            for file in files where file.pathExtension == "json" && FileManager.default.fileExists(atPath: file.path) {
                guard let s = Self.readState(file) else { continue }
                loaded[s.bookID] = loaded[s.bookID].map { $0.merged(with: s) } ?? s
                if file.deletingPathExtension().lastPathComponent != s.bookID { conflicts.append(file) }
            }
            let conflictIDs = Set(conflicts.compactMap { Self.readState($0)?.bookID })
            await MainActor.run {
                guard gen == self.generation else { return }
                for (id, disk) in loaded {
                    self.states[id] = self.states[id].map { $0.merged(with: disk) } ?? disk
                }
                for id in conflictIDs { self.flush(id) }
                for file in conflicts { try? FileManager.default.removeItem(at: file) }
                self.statesLoaded = true
            }
        }
    }

    nonisolated private static func readState(_ url: URL) -> ReadingState? {
        var result: ReadingState?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { u in
            if let data = try? Data(contentsOf: u) { result = try? JSONDecoder.books.decode(ReadingState.self, from: data) }
        }
        return result
    }

    func state(_ id: String) -> ReadingState {
        states[id] ?? ReadingState(bookID: id, fileName: books.first { $0.id == id }?.url.lastPathComponent ?? id)
    }

    func update(_ id: String, _ mutate: (inout ReadingState) -> Void) {
        var s = state(id)
        mutate(&s)
        states[id] = s
        scheduleSave(id)
    }

    private func scheduleSave(_ id: String) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            flush(id)
        }
    }

    func flushAll() {
        for id in pendingSaves.keys { flush(id) }
    }

    private func flush(_ id: String) {
        pendingSaves[id] = nil
        guard let s = states[id] else { return }
        let url = stateFile(id)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &error) { u in
            var toWrite = s
            if let data = try? Data(contentsOf: u), let disk = try? JSONDecoder.books.decode(ReadingState.self, from: data) {
                toWrite = s.merged(with: disk)
            }
            if let data = try? JSONEncoder.books.encode(toWrite) { try? data.write(to: u, options: .atomic) }
        }
        if let error { lastError = error.localizedDescription }
    }

    // MARK: Covers

    func cover(_ id: String) -> NSImage? {
        _ = coverVersion
        if let c = covers[id] { return c }
        guard let image = NSImage(contentsOf: coverFile(id)) else { return nil }
        covers[id] = image
        return image
    }

    // MARK: Importing & opening

    /// Copies books into the library folder. Returns the records of the copies.
    @discardableResult
    func importBooks(_ urls: [URL]) -> [BookRecord] {
        var imported: [BookRecord] = []
        for url in urls where BookFormat(url: url) != nil {
            let id = Self.bookID(for: url)
            if let existing = books.first(where: { $0.id == id && $0.inCloudLibrary }) {
                imported.append(existing)
                continue
            }
            if isInLibrary(url) {
                if let r = Self.record(url, inCloud: true) { imported.append(r) }
                continue
            }
            let dest = uniqueDestination(for: url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                if let r = Self.record(dest, inCloud: true) {
                    imported.append(r)
                    adopt(r)
                }
            } catch {
                lastError = "Couldn’t add “\(url.lastPathComponent)”: \(error.localizedDescription)"
            }
        }
        return imported
    }

    /// Resolves a file opened from Finder into a library record, copying it into the library when appropriate.
    func recordForOpening(_ url: URL) -> BookRecord? {
        guard let format = BookFormat(url: url) else {
            lastError = PublicationError.unsupportedFormat(url.pathExtension).localizedDescription
            return nil
        }
        if isInLibrary(url) {
            guard let r = Self.record(url, inCloud: true) else { return nil }
            adopt(r)
            return r
        }
        let id = Self.bookID(for: url)
        if let existing = books.first(where: { $0.id == id && $0.inCloudLibrary }) { return existing }

        let autoCopy = UserDefaults.standard.object(forKey: "autoCopyOpenedBooks") as? Bool ?? true
        if autoCopy && format != .pdf && format != .html && format != .txt && format != .markdown,
           let copy = importBooks([url]).first {
            return copy
        }
        guard let r = Self.record(url, inCloud: false) else { return nil }
        var recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        recents.removeAll { $0 == url.path }
        recents.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(200)), forKey: Self.recentsKey)
        adopt(r)
        return r
    }

    func copyToLibrary(_ book: BookRecord) {
        guard !book.inCloudLibrary, let copy = importBooks([book.url]).first else { return }
        if copy.id != book.id, let old = states[book.id] {
            // A renamed copy gets a new identity; carry the reading state over.
            update(copy.id) { s in
                var moved = old
                moved.bookID = copy.id
                moved.fileName = copy.url.lastPathComponent
                s = s.merged(with: moved)
            }
        }
        removeFromLibrary(book, trashFile: false)
        adopt(copy)
    }

    private func adopt(_ record: BookRecord) {
        if let i = books.firstIndex(where: { $0.id == record.id }) { books[i] = record } else { books.append(record) }
        ensureStatesAndMetadata()
    }

    func removeFromLibrary(_ book: BookRecord, trashFile: Bool) {
        if trashFile && book.inCloudLibrary {
            do { try FileManager.default.trashItem(at: book.url, resultingItemURL: nil) } catch {
                lastError = error.localizedDescription
                return
            }
        }
        var recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        recents.removeAll { $0 == book.url.path }
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
        books.removeAll { $0.id == book.id }
    }

    private func uniqueDestination(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = rootURL.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return candidate
    }

    func book(_ id: String) -> BookRecord? { books.first { $0.id == id } }

    var allCollections: [String] {
        Array(Set(states.values.flatMap(\.collections))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Downloads an evicted iCloud file and waits until it is local.
    func ensureDownloaded(_ book: BookRecord) async throws {
        guard !book.isDownloaded else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: book.url)
        for _ in 0..<600 {
            var url = book.url
            url.removeAllCachedResourceValues()
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            if status == nil || status == .current || status == .downloaded {
                if let i = books.firstIndex(where: { $0.id == book.id }) { books[i].isDownloaded = true }
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw PublicationError.corrupt("the download from iCloud timed out")
    }
}

extension JSONEncoder {
    static let books: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let books: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Title, author and a cover thumbnail, extracted off the main thread.
enum BookMetadata {
    struct Result { var title: String?; var author: String?; var coverJPEG: Data? }

    static func extract(_ url: URL, id: String, wantCover: Bool) -> Result {
        guard let format = BookFormat(url: url) else { return Result() }
        switch format {
        case .pdf:
            guard let doc = PDFDocument(url: url) else { return Result() }
            let attrs = doc.documentAttributes ?? [:]
            let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.count > 1 ? $0 : nil }
            let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var jpeg: Data?
            if wantCover, let page = doc.page(at: 0) {
                jpeg = page.thumbnail(of: NSSize(width: 600, height: 900), for: .cropBox).jpegData(maxHeight: 900)
            }
            return Result(title: title ?? url.deletingPathExtension().lastPathComponent, author: author, coverJPEG: jpeg)
        case .cbz, .cbr, .cb7, .cbt:
            let title = url.deletingPathExtension().lastPathComponent
            return Result(title: title, author: nil, coverJPEG: wantCover ? comicCover(url) : nil)
        default:
            guard let pub = try? BookLoader.load(url, bookID: id) else {
                return Result(title: url.deletingPathExtension().lastPathComponent)
            }
            let jpeg = wantCover ? pub.coverURL.flatMap { NSImage(contentsOf: $0)?.jpegData(maxHeight: 900) } : nil
            return Result(title: pub.title, author: pub.author, coverJPEG: jpeg)
        }
    }

    private static func comicCover(_ url: URL) -> Data? {
        guard let listing = run(["-tf", url.path]), let text = String(data: listing, encoding: .utf8) else { return nil }
        let first = text.split(separator: "\n").map(String.init)
            .filter { !$0.contains("__MACOSX") && ComicParser.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first
        guard let first, let data = run(["-xOf", url.path, first]), let image = NSImage(data: data) else { return nil }
        return image.jpegData(maxHeight: 900)
    }

    private static func run(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard let data = try? p.runCollecting(out) else { return nil }
        return p.terminationStatus == 0 || !data.isEmpty ? data : nil
    }
}

extension NSImage {
    func jpegData(maxHeight: CGFloat) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxHeight / CGFloat(cg.height))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

/// Recursive FSEvents watcher.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(url: URL, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handler(Array(array.prefix(count)))
        }
        stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                     UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
