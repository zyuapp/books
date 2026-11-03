import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LibrarySection: Hashable {
    case home, all, reading, finished
    case books, pdfs, comics, documents
    case collection(String)

    var title: String {
        switch self {
        case .home: "Home"
        case .all: "All Books"
        case .reading: "Reading"
        case .finished: "Finished"
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
        case .reading: "book"
        case .finished: "checkmark.circle"
        case .books: "book.closed"
        case .pdfs: "doc.richtext"
        case .comics: "photo.stack"
        case .documents: "doc.text"
        case .collection: "rectangle.stack"
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
    @AppStorage("coverSize") private var coverSize: Double = 150
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
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
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
        return section == .home ? "" : "\(n) item\(n == 1 ? "" : "s")"
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            Section("Library") {
                ForEach([LibrarySection.home, .all, .reading, .finished], id: \.self) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
            Section("Formats") {
                ForEach([LibrarySection.books, .pdfs, .comics, .documents], id: \.self) { s in
                    if count(s) > 0 { Label(s.title, systemImage: s.symbol).tag(s) }
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
        case .reading: return state.status == .reading
        case .finished: return state.status == .finished
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
            HomeView(open: open, menu: { AnyView(contextMenu(for: $0)) })
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize, maximum: coverSize * 1.25), spacing: 28, alignment: .top)], spacing: 34) {
                    ForEach(filtered) { book in
                        BookCard(book: book, width: coverSize)
                            .onTapGesture { open(book) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { open(book) }
                            .contextMenu { contextMenu(for: book) }
                            .draggable(book.id)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
            }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "Nothing Here Yet" : "No Results",
                                           systemImage: section?.symbol ?? "books.vertical",
                                           description: Text(query.isEmpty ? "Books you add will appear here." : "Try a different search."))
                }
            }
        }
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
        HeaderBar(title: section?.title ?? "Library", subtitle: subtitle) {
            Button {
                withAnimation(Motion.panel) { showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.leading").frame(width: 18, height: 18)
            }
            .glassButtonStyle()
            .help("Hide or show the sidebar")
            .accessibilityLabel("Toggle Sidebar")
            // At the sidebar's far edge while it shows.
            .frame(width: showSidebar ? max(44, sidebarWidth - HeaderBar<EmptyView, EmptyView>.leadingInset - 14) : nil, alignment: .trailing)
        } trailing: {
            HStack(spacing: 10) {
                HeaderSearchField(prompt: "Title, author or format", text: $query, focus: $searchFocused)
                Button(action: addBooks) {
                    Image(systemName: "plus").frame(width: 18, height: 18)
                }
                .glassButtonStyle()
                .help("Add books to your library (⇧⌘O)")
                .accessibilityLabel("Add Books")
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
                .foregroundStyle(LinearGradient(colors: [Color(hex: "#C96442"), Color(hex: "#8A3F26")], startPoint: .top, endPoint: .bottom))
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
            .tint(Color(hex: "#C96442"))
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
        let title = state.title ?? book.url.deletingPathExtension().lastPathComponent
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                CoverView(bookID: book.id, title: title, author: state.author)
                    .frame(width: width, height: width * 1.5)
                    .background {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.black)
                            .shadow(color: .black.opacity(hovering ? 0.32 : 0.2), radius: hovering ? 16 : 8, y: hovering ? 10 : 4)
                    }
                badge(state)
                    .padding(6)
            }
            .scaleEffect(hovering ? 1.03 : 1, anchor: .bottom)
            .animation(Motion.hover, value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(state.author ?? book.format.displayName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                if state.status == .reading {
                    ProgressView(value: state.progress)
                        .progressViewStyle(.linear)
                        .tint(Color(hex: "#C96442"))
                        .controlSize(.mini)
                        .padding(.top, 3)
                }
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
            Image(systemName: "checkmark").font(.caption.weight(.bold))
                .padding(6).glassSurface(in: .circle, tint: .green.opacity(0.5))
        }
    }
}

private struct HomeView: View {
    let open: (BookRecord) -> Void
    let menu: (BookRecord) -> AnyView
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
                    Shelf(title: "Continue Reading", books: Array(reading.dropFirst().prefix(14)), open: open, menu: menu)
                }
                Shelf(title: "Recently Added", books: Array(recentlyAdded), open: open, menu: menu)
            }
            .padding(.vertical, 24)
        }
    }
}

private struct HeroCard: View {
    let book: BookRecord
    let open: () -> Void
    @State private var library = LibraryStore.shared

    var body: some View {
        let state = library.state(book.id)
        let title = state.title ?? book.url.deletingPathExtension().lastPathComponent
        ZStack {
            CoverWash(bookID: book.id, title: title)
                .opacity(0.6)
                .overlay(LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.25)], startPoint: .leading, endPoint: .trailing))
                .clipped()
            HStack(spacing: 30) {
                CoverView(bookID: book.id, title: title, author: state.author)
                    .frame(width: 150, height: 225)
                    .background {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.black)
                            .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
                    }
                VStack(alignment: .leading, spacing: 10) {
                    Text("CONTINUE READING").font(.subheadline.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                    Text(title).font(.system(size: 30, weight: .semibold, design: .serif)).lineLimit(2)
                    if let author = state.author { Text(author).font(.title3).foregroundStyle(.secondary) }
                    if let label = state.position?.label {
                        Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 12) {
                        ProgressView(value: state.progress).tint(Color(hex: "#C96442")).frame(maxWidth: 220)
                        Text("\(Int((state.progress * 100).rounded()))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button(action: open) {
                        Label("Resume", systemImage: "book.fill").font(.headline).padding(.horizontal, 6)
                    }
                    .glassProminentButtonStyle()
                    .tint(Color(hex: "#C96442"))
                    .controlSize(.large)
                    .padding(.top, 6)
                }
                Spacer()
            }
            .padding(30)
        }
        .frame(height: 285)
        .glassSurface(in: .rect(cornerRadius: 28))
        .clipShape(.rect(cornerRadius: 28))
        .padding(.horizontal, 30)
        .onTapGesture(count: 2, perform: open)
    }
}

private struct Shelf: View {
    let title: String
    let books: [BookRecord]
    let open: (BookRecord) -> Void
    let menu: (BookRecord) -> AnyView

    var body: some View {
        if !books.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(.title2, design: .serif).weight(.semibold)).padding(.horizontal, 30)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 26) {
                        ForEach(books) { book in
                            BookCard(book: book, width: 128)
                                .onTapGesture { open(book) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { open(book) }
                                .contextMenu { menu(book) }
                                .draggable(book.id)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 10)
                }
            }
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
