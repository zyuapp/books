import Foundation

enum EPUBParser {
    static func parse(_ url: URL, into dir: URL) throws -> Publication {
        let root = dir.appendingPathComponent("epub", isDirectory: true)
        try Archive.extract(url, to: root)
        return try parseExtracted(root: root, source: url)
    }

    static func parseExtracted(root: URL, source: URL) throws -> Publication {
        try checkDRM(root)

        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        guard let container = try? XMLDocument(contentsOf: containerURL, options: [.nodeLoadExternalEntitiesNever]),
              let opfPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue
        else { throw PublicationError.corrupt("missing META-INF/container.xml") }

        let opfURL = root.appendingPathComponent(opfPath.removingPercentEncoding ?? opfPath)
        guard let opf = try? XMLDocument(contentsOf: opfURL, options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace])
        else { throw PublicationError.corrupt("unreadable package document") }

        func strings(_ xpath: String) -> [String] {
            ((try? opf.nodes(forXPath: xpath)) ?? []).compactMap {
                $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        }

        let title = strings("//*[local-name()='metadata']/*[local-name()='title']").first
            ?? source.deletingPathExtension().lastPathComponent
        let authors = strings("//*[local-name()='metadata']/*[local-name()='creator']")
        let language = strings("//*[local-name()='metadata']/*[local-name()='language']").first

        struct Item { var href: String; var mediaType: String; var properties: String }
        var manifest: [String: Item] = [:]
        for node in (try? opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? [] {
            guard let el = node as? XMLElement,
                  let id = el.attribute(forName: "id")?.stringValue,
                  let href = el.attribute(forName: "href")?.stringValue else { continue }
            manifest[id] = Item(
                href: href,
                mediaType: el.attribute(forName: "media-type")?.stringValue ?? "",
                properties: el.attribute(forName: "properties")?.stringValue ?? ""
            )
        }

        let globalFixed = strings("//*[local-name()='meta'][@property='rendition:layout']").first == "pre-paginated"
        let spineEl = (try? opf.nodes(forXPath: "//*[local-name()='spine']"))?.first as? XMLElement
        let rtl = spineEl?.attribute(forName: "page-progression-direction")?.stringValue == "rtl"

        var spine: [SpineItem] = []
        var spineIndexByPath: [String: Int] = [:]
        var nonLinear: [SpineItem] = []
        for node in (try? opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? [] {
            guard let el = node as? XMLElement,
                  let idref = el.attribute(forName: "idref")?.stringValue,
                  let item = manifest[idref] else { continue }
            let fileURL = opfURL.resolvingHref(item.href).url
            let props = el.attribute(forName: "properties")?.stringValue ?? ""
            let fixed = props.contains("rendition:layout-pre-paginated") || (globalFixed && !props.contains("rendition:layout-reflowable"))
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1000
            let spineItem = SpineItem(url: fileURL, weight: size, fixedLayout: fixed)
            if el.attribute(forName: "linear")?.stringValue == "no" {
                nonLinear.append(spineItem)
            } else {
                spineIndexByPath[fileURL.path] = spine.count
                spine.append(spineItem)
            }
        }
        // Non-linear items (footnotes, answer keys) stay reachable by link at the end.
        for item in nonLinear where spineIndexByPath[item.url.path] == nil {
            spineIndexByPath[item.url.path] = spine.count
            spine.append(item)
        }
        guard !spine.isEmpty else { throw PublicationError.corrupt("the book has no readable content") }

        // Cover: EPUB3 property, then EPUB2 <meta name="cover">, then guide.
        var coverURL: URL?
        if let item = manifest.values.first(where: { $0.properties.split(separator: " ").contains("cover-image") }) {
            coverURL = opfURL.resolvingHref(item.href).url
        } else if let id = strings("//*[local-name()='meta'][@name='cover']/@content").first,
                  let item = manifest[id] ?? manifest.values.first(where: { $0.href == id }),
                  item.mediaType.hasPrefix("image/") {
            coverURL = opfURL.resolvingHref(item.href).url
        } else if let item = manifest.values.first(where: {
            $0.mediaType.hasPrefix("image/") && $0.href.lowercased().contains("cover")
        }) {
            coverURL = opfURL.resolvingHref(item.href).url
        }

        // TOC: EPUB3 nav document, else NCX.
        var toc: [TOCEntry] = []
        if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }) {
            toc = parseNav(opfURL.resolvingHref(nav.href).url, spineIndexByPath: spineIndexByPath)
        }
        if toc.isEmpty {
            let ncxID = spineEl?.attribute(forName: "toc")?.stringValue
            let ncx = ncxID.flatMap { manifest[$0] }
                ?? manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" })
            if let ncx {
                toc = parseNCX(opfURL.resolvingHref(ncx.href).url, spineIndexByPath: spineIndexByPath)
            }
        }
        if toc.isEmpty {
            toc = spine.prefix(nonLinear.isEmpty ? spine.count : spine.count - nonLinear.count)
                .enumerated().map { i, _ in TOCEntry(title: "Section \(i + 1)", spineIndex: i) }
        }

        return Publication(
            kind: .reflowable, title: title,
            author: authors.isEmpty ? nil : authors.joined(separator: ", "),
            language: language, spine: spine, toc: toc, coverURL: coverURL,
            rightToLeft: rtl, rootDirectory: root, sourceURL: source
        )
    }

    private static func checkDRM(_ root: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("META-INF/rights.xml").path) {
            throw PublicationError.drmProtected
        }
        let encURL = root.appendingPathComponent("META-INF/encryption.xml")
        guard let enc = try? XMLDocument(contentsOf: encURL, options: []) else { return }
        let algorithms = ((try? enc.nodes(forXPath: "//*[local-name()='EncryptionMethod']/@Algorithm")) ?? [])
            .compactMap(\.stringValue)
        let fontObfuscation: Set = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        if algorithms.contains(where: { !fontObfuscation.contains($0) }) { throw PublicationError.drmProtected }
    }

    private static func parseNav(_ url: URL, spineIndexByPath: [String: Int]) -> [TOCEntry] {
        guard let doc = (try? XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]))
            ?? (try? XMLDocument(contentsOf: url, options: [.documentTidyHTML]))
        else { return [] }
        let navs = (try? doc.nodes(forXPath: "//*[local-name()='nav']")) ?? []
        let tocNav = navs.first(where: {
            ($0 as? XMLElement)?.attributes?.contains(where: { $0.localName == "type" && ($0.stringValue ?? "").contains("toc") }) == true
        }) ?? navs.first
        guard let ol = (tocNav as? XMLElement)?.elements(forLocalName: "ol").first else { return [] }

        func entries(_ ol: XMLElement) -> [TOCEntry] {
            ol.elements(forLocalName: "li").compactMap { li in
                let link = li.elements(forLocalName: "a").first ?? li.elements(forLocalName: "span").first
                let title = (link?.stringValue ?? "").collapsingWhitespace
                let children = li.elements(forLocalName: "ol").first.map(entries) ?? []
                guard let href = link?.attribute(forName: "href")?.stringValue else {
                    if let first = children.first, !title.isEmpty {
                        return TOCEntry(title: title, spineIndex: first.spineIndex, fragment: first.fragment, children: children)
                    }
                    return nil
                }
                let target = url.resolvingHref(href)
                guard let index = spineIndexByPath[target.url.path] else { return nil }
                return TOCEntry(title: title.isEmpty ? "Untitled" : title, spineIndex: index, fragment: target.fragment, children: children)
            }
        }
        return entries(ol)
    }

    private static func parseNCX(_ url: URL, spineIndexByPath: [String: Int]) -> [TOCEntry] {
        guard let doc = try? XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]),
              let navMap = (try? doc.nodes(forXPath: "//*[local-name()='navMap']"))?.first as? XMLElement
        else { return [] }

        func entries(_ parent: XMLElement) -> [TOCEntry] {
            parent.elements(forLocalName: "navPoint").compactMap { point in
                let title = point.elements(forLocalName: "navLabel").first?.stringValue?.collapsingWhitespace ?? "Untitled"
                guard let src = point.elements(forLocalName: "content").first?.attribute(forName: "src")?.stringValue
                else { return nil }
                let target = url.resolvingHref(src)
                guard let index = spineIndexByPath[target.url.path] else { return nil }
                return TOCEntry(title: title, spineIndex: index, fragment: target.fragment, children: entries(point))
            }
        }
        return entries(navMap)
    }
}

extension XMLElement {
    func elements(forLocalName name: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
    }
}
