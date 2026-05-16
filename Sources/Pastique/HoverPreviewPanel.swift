import AppKit
import Quartz
import QuickLookThumbnailing
import SwiftUI

// Floating preview that hovers next to the picker. Shows a larger view of
// whatever the user is hovering on. Two content modes:
//
// - imageWrapper: NSImageView, used for image clips and QL-thumbnailable files.
// - colorHosting: SwiftUI ColorPreviewCard, used for color-subtype clips
//   (swatch + HEX/RGB/HSL labels).
//
// Both live in the panel at all times; show() flips `isHidden` to pick one.

@MainActor
final class HoverPreviewPanel: NSPanel {
    static let contentSize = NSSize(width: 320, height: 320)
    /// Color clips don't benefit from the full square — the row already
    /// shows a swatch, and the panel mostly exists to surface HEX/RGB/HSL.
    /// Use a shorter, narrower frame so the preview stops dominating.
    static let colorSize = NSSize(width: 260, height: 180)

    private let imageWrapper: NSView
    private let imageView: NSImageView
    private let colorHosting: NSHostingView<AnyView>
    private var currentClipID: Int64?

    init() {
        let imgWrapper = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        imgWrapper.autoresizingMask = [.width, .height]

        let iv = NSImageView(frame: imgWrapper.bounds.insetBy(dx: 10, dy: 10))
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 8
        iv.layer?.masksToBounds = true
        iv.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor
        iv.autoresizingMask = [.width, .height]
        imgWrapper.addSubview(iv)

        self.imageWrapper = imgWrapper
        self.imageView = iv

        let host = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
        host.frame = NSRect(origin: .zero, size: Self.contentSize)
        host.autoresizingMask = [.width, .height]
        self.colorHosting = host

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        let container = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true

        let blur = NSVisualEffectView(frame: container.bounds)
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)

        container.addSubview(imgWrapper)
        container.addSubview(host)
        imgWrapper.isHidden = true
        host.isHidden = true

        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show the preview for `item`, anchored next to `anchor`. Hidden for
    /// content that isn't meaningfully different at a larger size (folders,
    /// generic file icons, plain text).
    func show(for item: ClipItem, store: ClipStore, anchor: NSRect) {
        if currentClipID == item.id, isVisible { reposition(anchor: anchor); return }
        currentClipID = item.id

        switch item.card {
        case .image:
            guard let img = imageForImageClip(item, store: store) else { hide(); return }
            showImageMode()
            imageView.image = img
            reposition(anchor: anchor)
            orderFront(nil)
        case .fileURL:
            // requestFileThumbnail handles its own show/hide.
            requestFileThumbnail(item, anchor: anchor)
        case .color:
            guard let raw = item.text, let parsed = parseColor(raw) else { hide(); return }
            colorHosting.rootView = AnyView(ColorPreviewCard(parsed: parsed))
            showColorMode()
            reposition(anchor: anchor)
            orderFront(nil)
        case .text, .url, .phone, .email, .creditCard, .ssn, .address, .command:
            hide()
        }
    }

    func hide() {
        currentClipID = nil
        orderOut(nil)
    }

    // MARK: - Mode switching

    private func showImageMode() {
        imageWrapper.isHidden = false
        colorHosting.isHidden = true
        resizePanel(to: Self.contentSize)
    }

    private func showColorMode() {
        imageWrapper.isHidden = true
        colorHosting.isHidden = false
        resizePanel(to: Self.colorSize)
    }

    private func resizePanel(to size: NSSize) {
        guard frame.size != size else { return }
        var f = frame
        f.size = size
        setFrame(f, display: false, animate: false)
    }

    // MARK: - Content resolution

    private func imageForImageClip(_ item: ClipItem, store: ClipStore) -> NSImage? {
        if let path = item.imagePath,
           let img = NSImage(contentsOf: store.imageFileURL(path)) {
            return img
        }
        if let data = item.thumbnail {
            return NSImage(data: data)
        }
        return nil
    }

    private func requestFileThumbnail(_ item: ClipItem, anchor: NSRect) {
        guard let first = item.fileURLs?.first, let url = URL(string: first) else {
            hide()
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
            hide()
            return
        }

        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: Self.contentSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        let expectedID = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            [weak self] (thumb: QLThumbnailRepresentation?, _: Error?) in
            DispatchQueue.main.async {
                guard let self = self, self.currentClipID == expectedID else { return }
                guard let nsImg = thumb?.nsImage else {
                    self.hide()
                    return
                }
                self.showImageMode()
                self.imageView.image = nsImg
                self.reposition(anchor: anchor)
                self.orderFront(nil)
            }
        }
    }

    // MARK: - Positioning

    private func reposition(anchor: NSRect) {
        let size = frame.size
        let gap: CGFloat = 8
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return }

        var x = anchor.maxX + gap
        if x + size.width > vis.maxX - 4 {
            x = anchor.minX - gap - size.width
        }
        x = max(vis.minX + 4, min(x, vis.maxX - size.width - 4))

        var y = anchor.maxY - size.height
        y = max(vis.minY + 4, min(y, vis.maxY - size.height - 4))

        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI color preview card

private struct ColorPreviewCard: View {
    let parsed: ParsedColor

    var body: some View {
        VStack(spacing: 0) {
            Color(nsColor: parsed.color)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
            VStack(alignment: .leading, spacing: 6) {
                row(label: "HEX", value: parsed.hex)
                row(label: "RGB", value: parsed.rgb)
                row(label: "HSL", value: parsed.hsl)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }
}
