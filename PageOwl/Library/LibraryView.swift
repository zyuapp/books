import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LibrarySection: Hashable {
    case home, all
    case books, pdfs, comics, documents
    case collection(String)

    var title: String {
        switch self {
        case .home: "Home"
        case .all: "All Books"
        case .books: "Books"
        case .pdfs: "PDFs"
        case .comics: "Comics"
        case .documents: "Documents"
        case .collection(let name): name
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .all: "books.vertical"
        case .books: "book.closed"
        case .pdfs: "doc.richtext"
        case .comics: "photo.stack"
        case .documents: "doc.text"
        case .collection: "rectangle.stack"
        }
    }
}

enum LibraryStatusFilter: String, CaseIterable, Identifiable {
    case all, reading, finished
    var id: String { rawValue }
    var name: String {
        switch self {
        case .all: "All"
        case .reading: "Reading"
        case .finished: "Finished"
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, author, added, progress
    var id: String { rawValue }
    var name: String {
        switch self {
        case .recent: "Recently Read"
        case .title: "Title"
        case .author: "Author"
        case .added: "Date Added"
        case .progress: "Progress"
        }
    }
}

struct LibraryView: View {
    @State private var library = LibraryStore.shared
    @State private var section: LibrarySection? = .home
    @State private var query = ""
    @AppStorage("librarySort") private var sort: LibrarySort = .recent
    @State private var status: LibraryStatusFilter = .all
    @State private var gridWidth: CGFloat = 0
    @State private var newCollection: String?
    @State private var isDropTarget = false
    @State private var showSidebar = true
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 230
    @FocusState private var searchFocused: Bool
    @State private var searchFocus = LibrarySearchFocus.shared

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .padding(.top, HeaderBar<EmptyView, EmptyView>.height + 12)
                    .frame(width: sidebarWidth)
                    .background(Color.primary.opacity(0.05))
                    .background(Color(nsColor: .windowBackgroundColor))
                SidebarDivider(width: $sidebarWidth)
            }
            detail
                .clipped()
                .padding(.top, HeaderBar<EmptyView, EmptyView>.height)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .navigationTitle(section?.title ?? "Library")
        }
        .overlay(alignment: .top) { header }
        .ignoresSafeArea(edges: .top)
        .onChange(of: searchFocus.requested) { _, _ in searchFocused = true }
        .onAppear {
            library.start()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            Task { await importDropped(providers) }
            return true
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(10)
                    .overlay(Label("Add to Library", systemImage: "plus.circle.fill").font(.title2.weight(.semibold))
                        .padding(18).glassSurface(in: .capsule))
                    .allowsHitTesting(false)
            }
        }
        .alert("New Collection", isPresented: Binding(get: { newCollection != nil }, set: { if !$0 { newCollection = nil } })) {
            TextField("Name", text: Binding(get: { newCollection ?? "" }, set: { newCollection = $0 }))
            Button("Create") {
                if let name = newCollection?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    LibraryCollections.pending.insert(name)
                    section = .collection(name)
                }
                newCollection = nil
            }
            Button("Cancel", role: .cancel) { newCollection = nil }
        }
        .alert("Something went wrong", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.lastError ?? "")
        }
    }

    private var subtitle: String {
        let n = filtered.count
        return "\(n) \(n == 1 ? "book" : "books")"
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            Section("Library") {
                ForEach([LibrarySection.home, .all], id: \.self) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
            let formats = [LibrarySection.books, .pdfs, .comics, .documents].filter { count($0) > 0 }
            if !formats.isEmpty {
                Section("Formats") {
                    ForEach(formats, id: \.self) { s in
                        Label(s.title, systemImage: s.symbol).tag(s)
                    }
                }
            }
            Section("Collections") {
                ForEach(collections, id: \.self) { name in
                    Label(name, systemImage: "rectangle.stack").tag(LibrarySection.collection(name))
                        .dropDestination(for: String.self) { ids, _ in
                            for id in ids { toggleCollection(name, for: id, on: true) }
                            return true
                        }
                }
                Button { newCollection = "" } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var collections: [String] {
        Array(Set(library.allCollections).union(LibraryCollections.pending)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func count(_ s: LibrarySection) -> Int { library.books.filter { matches($0, s) }.count }

    // MARK: Filtering

    private func matches(_ book: BookRecord, _ s: LibrarySection) -> Bool {
        let state = library.state(book.id)
        switch s {
        case .home, .all: return true
        case .books: return [.epub, .mobi, .azw3, .fb2].contains(book.format)
        case .pdfs: return book.format == .pdf
        case .comics: return book.format.isComic
        case .documents: return [.txt, .markdown, .rtf, .docx, .odt, .html].contains(book.format)
        case .collection(let name): return state.collections.contains(name)
        }
    }

    private var filtered: [BookRecord] {
        let s = section ?? .all
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = library.books.filter { book in
            guard matches(book, s) else { return false }
            switch status {
            case .all: break
            case .reading: guard library.state(book.id).status == .reading else { return false }
            case .finished: guard library.state(book.id).status == .finished else { return false }
            }
            guard !q.isEmpty else { return true }
            let st = library.state(book.id)
            return [st.title, st.author, book.url.lastPathComponent, book.format.displayName]
                .compactMap { $0?.lowercased() }.contains { $0.contains(q) }
        }
        return sorted(list)
    }

    private func sorted(_ list: [BookRecord]) -> [BookRecord] {
        list.sorted { a, b in
            let sa = library.state(a.id), sb = library.state(b.id)
            switch sort {
            case .recent: return (sa.lastOpened ?? sa.added) > (sb.lastOpened ?? sb.added)
            case .title: return title(a).localizedStandardCompare(title(b)) == .orderedAscending
            case .author: return (sa.author ?? "~").localizedStandardCompare(sb.author ?? "~") == .orderedAscending
            case .added: return sa.added > sb.added
            case .progress: return sa.progress > sb.progress
            }
        }
    }

    private func title(_ b: BookRecord) -> String {
        library.state(b.id).title ?? b.url.deletingPathExtension().lastPathComponent
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if library.books.isEmpty && !library.isScanning {
            EmptyLibrary(onAdd: addBooks)
        } else if section == .home && query.isEmpty {
            HomeView(open: open, menu: { AnyView(contextMenu(for: $0)) }, seeAll: { status = $0; section = .all })
        } else {
            ScrollView {
                if !filtered.isEmpty || status != .all { gridHeader }
                let metrics = CardMetrics(available: gridWidth)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(metrics.card), spacing: CardMetrics.gap, alignment: .top), count: metrics.count),
                          alignment: .leading, spacing: 30) {
                    ForEach(filtered) { book in
                        BookCard(book: book, width: metrics.card)
                            .onTapGesture { open(book) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { open(book) }
                            .contextMenu { contextMenu(for: book) }
                            .draggable(book.id)
                    }
                }
                .padding(.horizontal, CardMetrics.inset)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .hiddenTopScrollEdge()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .overlay {
                if filtered.isEmpty {
                    if query.isEmpty && status != .all {
                        EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "No \(status.name) Books",
                                       detail: "Nothing here matches this filter.", large: true,
                                       actionTitle: "Show All", action: { status = .all })
                    } else if query.isEmpty {
                        EmptyStateView(symbol: section?.symbol ?? "books.vertical", title: "Nothing Here Yet",
                                       detail: "Books you add will appear here.", large: true)
                    } else {
                        EmptyStateView(symbol: "magnifyingglass", title: "No Results", detail: "Try a different search.", large: true,
                                       actionTitle: "Clear Search", action: { query = "" })
                    }
                }
            }
        }
    }

    private var gridHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(query.isEmpty ? (section?.title ?? "Library") : "Results for “\(query)”")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .lineLimit(1)
            Text(subtitle).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Menu {
                Picker("Show", selection: $status) {
                    ForEach(LibraryStatusFilter.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("Show: \(status.name)").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Show")
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("Sort: \(sort.name)").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Sort by")
        }
        .padding(.horizontal, 30)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private func contextMenu(for book: BookRecord) -> some View {
        let state = library.state(book.id)
        Button("Open") { open(book) }
        Divider()
        if state.status != .finished {
            Button("Mark as Finished") { setStatus(book, .finished) }
        }
        if state.status != .unread {
            Button("Mark as Unread") { setStatus(book, .unread) }
        }
        Menu("Collections") {
            ForEach(collections, id: \.self) { name in
                Toggle(name, isOn: Binding(
                    get: { library.state(book.id).collections.contains(name) },
                    set: { toggleCollection(name, for: book.id, on: $0) }
                ))
            }
            if !collections.isEmpty { Divider() }
            Button("New Collection…") { newCollection = "" }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([book.url]) }
        if !book.inCloudLibrary {
            Button("Copy to Library") { library.copyToLibrary(book) }
        }
        Divider()
        if book.inCloudLibrary {
            Button("Move to Trash", role: .destructive) { library.removeFromLibrary(book, trashFile: true) }
        } else {
            Button("Remove from Library") { library.removeFromLibrary(book, trashFile: false) }
        }
    }

    // MARK: Header

    private var header: some View {
        HeaderBar(title: "", subtitle: nil) {
            HeaderButtonGroup {
                HeaderButton(symbol: "sidebar.leading", label: "Toggle Sidebar", tooltip: "Hide or show the sidebar") {
                    withAnimation(Motion.panel) { showSidebar.toggle() }
                }
            }
            // At the sidebar's far edge while it shows.
            .frame(width: showSidebar ? max(44, sidebarWidth - HeaderBar<EmptyView, EmptyView>.leadingInset - 14) : nil, alignment: .trailing)
        } trailing: {
            HStack(spacing: 10) {
                HeaderSearchField(prompt: "Title, author or format", text: $query, focus: $searchFocused)
                HeaderButtonGroup {
                    HeaderButton(symbol: "plus", label: "Add Books", tooltip: "Add books to your library (⇧⌘O)", action: addBooks)
                }
            }
        }
    }

    // MARK: Actions

    private func open(_ book: BookRecord) {
        OpenBridge.shared.openBook(book.id)
    }

    private func setStatus(_ book: BookRecord, _ status: ReadingStatus) {
        library.update(book.id) { s in
            s.status = status
            s.statusUpdated = Date()
            if status == .unread { s.position = nil; s.positionUpdated = Date() }
        }
    }

    private func toggleCollection(_ name: String, for id: String, on: Bool) {
        library.update(id) { s in
            if on { if !s.collections.contains(name) { s.collections.append(name) } } else { s.collections.removeAll { $0 == name } }
            s.collectionsUpdated = Date()
        }
        LibraryCollections.pending.remove(name)
    }

    private func addBooks() {
        AppActions.addBooks()
    }

    private func importDropped(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for p in providers {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let u = URL(dataRepresentation: url, relativeTo: nil) { urls.append(u) }
        }
        library.importBooks(urls)
    }
}

/// Collections that exist only until their first book is added.
@MainActor
enum LibraryCollections {
    static var pending: Set<String> = []
}

private struct EmptyLibrary: View {
    let onAdd: () -> Void
    @State private var library = LibraryStore.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 64))
                .foregroundStyle(LinearGradient(colors: [Color.brand, Color(hex: "#8A3F26")], startPoint: .top, endPoint: .bottom))
                .symbolEffect(.bounce, options: .nonRepeating)
            Text("Your library is empty").font(.system(.largeTitle, design: .serif).weight(.semibold))
            Text("Drop EPUB, PDF, MOBI, AZW3, FB2, comics or documents here.\n"
                 + (library.usesICloud ? "They’re stored in iCloud Drive so every Mac stays in sync." : "They’re stored in Documents › Books."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(action: onAdd) {
                Label("Add Books", systemImage: "plus").font(.headline).padding(.horizontal, 8)
            }
            .glassProminentButtonStyle()
            .tint(Color.brand)
            .controlSize(.extraLarge)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BookCard: View {
    let book: BookRecord
    let width: CGFloat
    @State private var library = LibraryStore.shared
    @State private var hovering = false

    var body: some View {
        let state = library.state(book.id)
        let title = (state.title ?? book.url.deletingPathExtension().lastPathComponent).mainTitle
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                CoverView(bookID: book.id, title: title, author: state.author,
                          shadowOpacity: hovering ? 0.32 : 0.2, shadowRadius: hovering ? 16 : 8, shadowY: hovering ? 10 : 4)
                    .frame(width: width, height: width * 1.5)
                badge(state)
                    .padding(6)
            }
            .scaleEffect(hovering ? 1.03 : 1, anchor: .bottom)
            .animation(Motion.hover, value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).lineLimit(2, reservesSpace: true)
                Text(state.author ?? " ").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                ReadingProgressBar(value: state.progress, height: 3)
                    .opacity(state.status == .reading ? 1 : 0)
                    .padding(.top, 5)
            }
            .frame(width: width, alignment: .leading)
        }
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(title: title, state: state))
    }

    private func accessibilityText(title: String, state: ReadingState) -> String {
        var parts = [title]
        if let a = state.author { parts.append("by \(a)") }
        switch state.status {
        case .unread: parts.append("new")
        case .reading: parts.append("\(Int((state.progress * 100).rounded())) percent read")
        case .finished: parts.append("finished")
        }
        if !book.isDownloaded { parts.append("in iCloud") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func badge(_ state: ReadingState) -> some View {
        if !book.isDownloaded {
            Image(systemName: "icloud.and.arrow.down").font(.caption.weight(.semibold))
                .padding(6).glassSurface(in: .circle)
        } else if state.status == .finished {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black.opacity(0.75))
                .padding(5).background(.white, in: .circle)
                .overlay(Circle().strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .offset(x: 12, y: 12)
        }
    }
}

private struct HomeView: View {
    let open: (BookRecord) -> Void
    let menu: (BookRecord) -> AnyView
    let seeAll: (LibraryStatusFilter) -> Void
    @State private var library = LibraryStore.shared

    var body: some View {
        let reading = library.books
            .filter { library.state($0.id).status == .reading }
            .sorted { (library.state($0.id).lastOpened ?? .distantPast) > (library.state($1.id).lastOpened ?? .distantPast) }
        let recentlyAdded = library.books.sorted { library.state($0.id).added > library.state($1.id).added }.prefix(14)

        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                if let current = reading.first {
                    HeroCard(book: current, open: { open(current) })
                        .contextMenu { menu(current) }
                }
                if reading.count > 1 {
                    Shelf(title: "Continue Reading", books: Array(reading.dropFirst().prefix(14)), open: open, menu: menu, seeAll: { seeAll(.reading) })
                }
                Shelf(title: "Recently Added", books: Array(recentlyAdded), open: open, menu: menu, seeAll: { seeAll(.all) })
            }
            .padding(.vertical, 24)
        }
        .hiddenTopScrollEdge()
    }
}

private struct HeroCard: View {
    let book: BookRecord
    let open: () -> Void
    @State private var library = LibraryStore.shared

    var body: some View {
        let state = library.state(book.id)
        let title = (state.title ?? book.url.deletingPathExtension().lastPathComponent).mainTitle
        HStack(alignment: .top, spacing: 32) {
            CoverView(bookID: book.id, title: title, author: state.author, shadowOpacity: 0.3, shadowRadius: 18, shadowY: 10)
                .frame(width: 150, height: 225)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 34, weight: .semibold, design: .serif)).lineLimit(2).padding(.top, 10)
                if let author = state.author { Text(author).font(.title3).foregroundStyle(.secondary) }
                if let label = state.position?.label {
                    Text(label).font(.body).foregroundStyle(.secondary).lineLimit(1).padding(.top, 4)
                }
                ReadingProgressBar(value: state.progress, height: 5).frame(maxWidth: 340).padding(.top, 6)
                HStack(spacing: 14) {
                    Button(action: open) {
                        Text("Resume").font(.headline).padding(.horizontal, 8)
                    }
                    .glassProminentButtonStyle()
                    .tint(Color.brand)
                    .controlSize(.large)
                    Text(summary(state)).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .padding(.top, 8)
        .onTapGesture(count: 2, perform: open)
    }

    private func summary(_ state: ReadingState) -> String {
        var parts = ["\(Int((state.progress * 100).rounded()))% read"]
        let highlights = state.liveHighlights.count, bookmarks = state.liveBookmarks.count
        if highlights > 0 { parts.append("\(highlights) highlight\(highlights == 1 ? "" : "s")") }
        if bookmarks > 0 { parts.append("\(bookmarks) bookmark\(bookmarks == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

/// The card grid every library view shares: whole cards that fill the width.
private struct CardMetrics {
    static let inset: CGFloat = 30
    static let gap: CGFloat = 24
    private static let minimumCard: CGFloat = 140
    private static let maximumCard: CGFloat = 170

    let count: Int
    let card: CGFloat

    init(available: CGFloat) {
        let room = max(0, available - Self.inset * 2)
        count = max(1, Int((room + Self.gap) / (Self.minimumCard + Self.gap)))
        card = min(Self.maximumCard, max(Self.minimumCard, (room - Self.gap * CGFloat(count - 1)) / CGFloat(count)))
    }
}

/// One row of whole covers sized to fill the width; the rest are a click away through See All.
private struct Shelf: View {
    let title: String
    let books: [BookRecord]
    let open: (BookRecord) -> Void
    let menu: (BookRecord) -> AnyView
    var seeAll: (() -> Void)?
    @State private var available: CGFloat = 0

    var body: some View {
        let metrics = CardMetrics(available: available)
        if !books.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(.title2, design: .serif).weight(.semibold))
                    Spacer()
                    if let seeAll, books.count > metrics.count {
                        Button("See All", action: seeAll).buttonStyle(.plain).foregroundStyle(Color.brand).font(.body.weight(.medium))
                    }
                }
                .padding(.horizontal, CardMetrics.inset)
                HStack(alignment: .top, spacing: CardMetrics.gap) {
                    ForEach(books.prefix(metrics.count)) { book in
                        BookCard(book: book, width: metrics.card)
                            .onTapGesture { open(book) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { open(book) }
                            .contextMenu { menu(book) }
                            .draggable(book.id)
                    }
                }
                .padding(.horizontal, CardMetrics.inset)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        }
    }
}

/// The line between the sidebar and the content; drag it to resize the sidebar.
private struct SidebarDivider: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                    .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(300, max(200, start + drag.translation.width))
                    }.onEnded { _ in startWidth = nil })
            }
    }
}
