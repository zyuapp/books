import AppKit
import SwiftUI
import WebKit

/// A ```mermaid block drawn as a diagram, falling back to its source when Mermaid can't parse it.
struct MermaidDiagram: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 0
    @State private var failed = false
    @State private var showsSource = false
    @State private var enlarged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(failed ? "Diagram couldn’t be drawn" : "Diagram", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !failed {
                    Button(showsSource ? "Show Diagram" : "Show Source") { showsSource.toggle() }
                    Button { enlarged = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("Enlarge Diagram")
                        .accessibilityLabel("Enlarge Diagram")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy Mermaid Source")
                .accessibilityLabel("Copy Mermaid Source")
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)

            if showsSource || failed {
                Text(source).font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MermaidWebView(source: source, isDark: colorScheme == .dark, height: $height, failed: $failed)
                    .frame(height: height > 0 ? height : 80)
                    .overlay {
                        if height == 0 {
                            ProgressView().controlSize(.small)
                        } else {
                            Color.clear.contentShape(Rectangle()).onTapGesture { enlarged = true }
                                .help("Click to enlarge")
                        }
                    }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .sheet(isPresented: $enlarged) {
            EnlargedDiagram(source: source, isDark: colorScheme == .dark)
        }
    }
}

private struct EnlargedDiagram: View {
    let source: String
    let isDark: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 0
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            MermaidWebView(source: source, isDark: isDark, passesScroll: false, height: $height, failed: $failed)
                .padding([.horizontal, .bottom], 20)
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 620, idealHeight: 760)
    }
}

private struct MermaidWebView: NSViewRepresentable {
    let source: String
    let isDark: Bool
    var passesScroll = true
    @Binding var height: CGFloat
    @Binding var failed: Bool

    private static let page = Bundle.main.url(forResource: "mermaid", withExtension: "html")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "diagram")
        let web = passesScroll ? ScrollPassingWebView(frame: .zero, configuration: config) : WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        if let page = Self.page {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            failed = true
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.parent.source != source || coordinator.parent.isDark != isDark
        coordinator.parent = self
        if changed { coordinator.render(in: web) }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MermaidWebView
        private var loaded = false

        init(_ parent: MermaidWebView) { self.parent = parent }

        func render(in web: WKWebView) {
            guard loaded else { return }
            web.callAsyncJavaScript("await render(src, dark)", arguments: ["src": parent.source, "dark": parent.isDark],
                                    in: nil, in: .page, completionHandler: nil)
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            render(in: web)
        }

        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url == MermaidWebView.page ? .allow : .cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let h = body["height"] as? Double, h > 0 { parent.height = h }
            if body["error"] != nil { parent.failed = true }
        }
    }
}

/// Sized to its diagram, so wheel events belong to the chat around it.
private final class ScrollPassingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
