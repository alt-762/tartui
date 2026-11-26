// Renders an SVG to a square PNG with a transparent background using WebKit.
// Usage: swift scripts/render_icon.swift <input.svg> <output.png> [size]
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: render_icon.swift <input.svg> <output.png> [size]\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1]).standardizedFileURL
let output = URL(fileURLWithPath: args[2]).standardizedFileURL
let size = args.count > 3 ? (Int(args[3]) ?? 1024) : 1024

final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    init(size: Int) {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        webView.setValue(false, forKey: "drawsBackground")
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        let svg = (try? String(contentsOf: input, encoding: .utf8)) ?? ""
        let html = """
        <!doctype html><html><head><style>
        html,body{margin:0;padding:0;background:transparent;overflow:hidden}
        svg{display:block;width:\(size)px;height:\(size)px}
        </style></head><body>\(svg)</body></html>
        """
        webView.loadHTMLString(html, baseURL: input.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give WebKit a moment to paint filters before snapshotting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.snapshot() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("load failed: \(error)")
    }

    func snapshot() {
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: size, height: size)
        config.snapshotWidth = NSNumber(value: size)
        webView.takeSnapshot(with: config) { image, error in
            guard let image else { self.fail("snapshot failed: \(String(describing: error))"); return }
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { self.fail("bitmap alloc failed"); return }
            rep.size = NSSize(width: size, height: size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.clear.set()
            NSRect(x: 0, y: 0, width: size, height: size).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { self.fail("png encode failed"); return }
            do {
                try png.write(to: output)
                print("Wrote \(output.path) (\(size)x\(size))")
                exit(0)
            } catch {
                self.fail("write failed: \(error)")
            }
        }
    }

    func fail(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(size: size)
renderer.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { renderer.fail("timed out") }
app.run()
