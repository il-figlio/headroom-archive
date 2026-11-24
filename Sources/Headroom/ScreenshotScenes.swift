import AppKit
import SwiftUI
import HeadroomCore

/// README scenes: the shipped notch and popover views, unchanged, placed at
/// the top of a synthetic screen. Everything around them (wallpaper, menu
/// bar, status icons) is drawn here from generic shapes, text, and SF Symbols.
enum ScreenshotScenes {
    static func render(directory: URL) throws {
        let widgets = PanelWidgets.shared
        // A laptop with a notch: Limits on, Agents off (the defaults once
        // Limits is turned on). Visible frame of a 956 pt tall display.
        widgets.setForScreenshots([.memory, .disk, .quota])
        widgets.setScreenLimit(956 - LaptopScene.menuBar - PanelMetrics.screenMargin)
        let laptop = MemoryMonitor(preview: true, machine: .laptop)
        try ScreenshotExport.render(LaptopScene(monitor: laptop), size: LaptopScene.size, title: nil, scale: 2,
                                    to: directory.appendingPathComponent("scene-laptop.png"))
        // A large display without a notch: menu-bar placement, Agents on,
        // Limits hidden to keep the panel the same height as the laptop's.
        widgets.setForScreenshots([.memory, .disk, .agents])
        widgets.setScreenLimit(1440 - DesktopScene.menuBar - PanelMetrics.screenMargin)
        let desktop = MemoryMonitor(preview: true, machine: .desktop)
        try ScreenshotExport.render(DesktopScene(monitor: desktop), size: DesktopScene.size, title: nil, scale: 2,
                                    to: directory.appendingPathComponent("scene-desktop.png"))
        widgets.setForScreenshots([.memory, .disk, .quota])
        widgets.setScreenLimit(900 - PanelMetrics.screenMargin)
    }

    /// Both scenes share one height so they sit side by side in the README;
    /// both panels are about 740 pt tall with their widget sets.
    static let height: CGFloat = 830
}

// MARK: - Laptop: the panel drops from the notch

private struct LaptopScene: View {
    @ObservedObject var monitor: MemoryMonitor
    static let menuBar: CGFloat = 34
    /// Width of the camera housing between the auxiliary top areas.
    static let notchGap: CGFloat = 184
    static var size: NSSize { NSSize(width: 1060, height: ScreenshotScenes.height) }

    var body: some View {
        // Same width rule as NotchController.render().
        let width = max(PanelMetrics.width, Self.notchGap + 140)
        ZStack(alignment: .top) {
            Wallpaper.laptop.view(size: Self.size)
            MenuBarStrip(height: Self.menuBar) {
                MenuTitles(app: "Finder", menus: ["File", "Edit", "View", "Window", "Help"])
            } trailing: {
                HStack(spacing: 18) {
                    StatusSymbol(name: "battery.75percent", size: 17)
                    StatusSymbol(name: "wifi")
                    StatusSymbol(name: "switch.2")
                    Clock()
                }
            }
            NotchView(monitor: monitor, gap: Self.notchGap, topHeight: Self.menuBar, expanded: true, open: {}, close: {})
                .frame(width: width, height: Self.menuBar + PanelMetrics.size().height)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
    }
}

// MARK: - Desktop: the popover drops from the status item

private struct DesktopScene: View {
    @ObservedObject var monitor: MemoryMonitor
    static let menuBar: CGFloat = 24
    static var size: NSSize { NSSize(width: 1140, height: ScreenshotScenes.height) }
    private static let trailingPadding: CGFloat = 12
    private static let itemSpacing: CGFloat = 18
    private static let symbolWidth: CGFloat = 20
    private static let arrow = CGSize(width: 24, height: 11)
    private static let popoverMargin: CGFloat = 8

    var body: some View {
        let item = StatusItemButton.size(for: monitor)
        // Right to left: clock, Control Center, Spotlight, then Headroom.
        let fromRight = Self.trailingPadding + Clock.width + Self.itemSpacing + Self.symbolWidth * 2
            + Self.itemSpacing * 2 + item.width / 2
        let itemCenter = Self.size.width - fromRight
        let panel = PanelMetrics.size()
        // NSPopover centers on the item, then slides to stay on screen.
        let popoverX = min(itemCenter - panel.width / 2, Self.size.width - panel.width - Self.popoverMargin)
        ZStack(alignment: .topLeading) {
            Wallpaper.desktop.view(size: Self.size)
            MenuBarStrip(height: Self.menuBar) {
                MenuTitles(app: "Finder", menus: ["File", "Edit", "View", "Window", "Help"])
            } trailing: {
                HStack(spacing: Self.itemSpacing) {
                    StatusItemButton(monitor: monitor).frame(width: item.width, height: Self.menuBar)
                    StatusSymbol(name: "magnifyingglass", size: 14).frame(width: Self.symbolWidth)
                    StatusSymbol(name: "switch.2").frame(width: Self.symbolWidth)
                    Clock().frame(width: Clock.width)
                }
            }
            Popover(arrowX: itemCenter - popoverX, arrow: Self.arrow) {
                PanelView(monitor: monitor, close: {})
            }
            .frame(width: panel.width, height: panel.height + Self.arrow.height)
            .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
            .offset(x: popoverX, y: Self.menuBar + 2)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }
}

// MARK: - Menu bar pieces

private struct MenuBarStrip<Leading: View, Trailing: View>: View {
    let height: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .foregroundStyle(Color.white.opacity(0.94))
        .background(Color.black.opacity(0.26))
        .environment(\.colorScheme, .dark)
    }
}

private struct MenuTitles: View {
    let app: String
    let menus: [String]
    var body: some View {
        HStack(spacing: 20) {
            Text(app).font(.system(size: 13, weight: .bold))
            ForEach(menus, id: \.self) { Text($0).font(.system(size: 13)) }
        }
    }
}

private struct StatusSymbol: View {
    let name: String
    var size: CGFloat = 15
    var body: some View { Image(systemName: name).font(.system(size: size, weight: .regular)) }
}

private struct Clock: View {
    static let text = "Tue Nov 24  9:41 AM"
    static let font = NSFont.systemFont(ofSize: 13)
    static var width: CGFloat { ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) + 2 }
    var body: some View { Text(Self.text).font(Font(Self.font)).lineLimit(1).fixedSize() }
}

/// The real status-item content: the same image and attributed title the
/// app sets on its `NSStatusBarButton`, drawn by AppKit.
private struct StatusItemButton: NSViewRepresentable {
    let monitor: MemoryMonitor
    /// Status items pad their button a little on each side.
    static func size(for monitor: MemoryMonitor) -> CGSize {
        let fitting = button(for: monitor).fittingSize
        return CGSize(width: ceil(fitting.width) + 8, height: fitting.height)
    }
    static func button(for monitor: MemoryMonitor) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.image = StatusIndicator.image()
        button.imagePosition = .imageLeading
        button.attributedTitle = StatusIndicator.title(for: monitor)
        button.appearance = NSAppearance(named: .darkAqua)
        return button
    }
    func makeNSView(context: Context) -> NSButton { Self.button(for: monitor) }
    func updateNSView(_ nsView: NSButton, context: Context) {}
}

/// NSPopover's frame: a rounded body with an arrow pointing at the item.
private struct Popover<Content: View>: View {
    let arrowX: CGFloat
    let arrow: CGSize
    @ViewBuilder var content: Content
    private let radius: CGFloat = 16
    var body: some View {
        let shape = PopoverShape(arrowX: arrowX, arrow: arrow, radius: radius)
        ZStack(alignment: .top) {
            shape.fill(Color(nsColor: .windowBackgroundColor))
            content.clipShape(RoundedRectangle(cornerRadius: radius)).padding(.top, arrow.height)
            shape.stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct PopoverShape: Shape {
    let arrowX: CGFloat
    let arrow: CGSize
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let top = arrow.height, r = radius, w = rect.width, h = rect.height
        let left = arrowX - arrow.width / 2, right = arrowX + arrow.width / 2
        var path = Path()
        path.move(to: CGPoint(x: r, y: top))
        path.addLine(to: CGPoint(x: left, y: top))
        path.addCurve(to: CGPoint(x: arrowX, y: 0), control1: CGPoint(x: left + arrow.width * 0.32, y: top),
                      control2: CGPoint(x: arrowX - arrow.width * 0.14, y: 0))
        path.addCurve(to: CGPoint(x: right, y: top), control1: CGPoint(x: arrowX + arrow.width * 0.14, y: 0),
                      control2: CGPoint(x: right - arrow.width * 0.32, y: top))
        path.addLine(to: CGPoint(x: w - r, y: top))
        path.addArc(tangent1End: CGPoint(x: w, y: top), tangent2End: CGPoint(x: w, y: top + r), radius: r)
        path.addLine(to: CGPoint(x: w, y: h - r))
        path.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: w - r, y: h), radius: r)
        path.addLine(to: CGPoint(x: r, y: h))
        path.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: h - r), radius: r)
        path.addLine(to: CGPoint(x: 0, y: top + r))
        path.addArc(tangent1End: CGPoint(x: 0, y: top), tangent2End: CGPoint(x: r, y: top), radius: r)
        path.closeSubpath()
        return path
    }
}

// MARK: - Wallpaper

/// Soft abstract gradients drawn with Core Graphics: a dark base and a few
/// large, feathered color fields. Positions are fractions of the canvas,
/// measured from the top-left.
private struct Wallpaper {
    struct Glow { let x, y, rx, ry: CGFloat; let rgb: (CGFloat, CGFloat, CGFloat); let alpha: CGFloat }
    let top: (CGFloat, CGFloat, CGFloat)
    let bottom: (CGFloat, CGFloat, CGFloat)
    let glows: [Glow]

    static let laptop = Wallpaper(
        top: (0.07, 0.08, 0.16), bottom: (0.10, 0.06, 0.14),
        glows: [Glow(x: 0.12, y: 0.78, rx: 0.55, ry: 0.65, rgb: (0.10, 0.45, 0.55), alpha: 0.65),
                Glow(x: 0.92, y: 0.25, rx: 0.50, ry: 0.70, rgb: (0.42, 0.24, 0.66), alpha: 0.60),
                Glow(x: 0.70, y: 1.05, rx: 0.45, ry: 0.45, rgb: (0.80, 0.42, 0.30), alpha: 0.40),
                Glow(x: 0.30, y: 0.05, rx: 0.40, ry: 0.35, rgb: (0.22, 0.30, 0.62), alpha: 0.45)])
    static let desktop = Wallpaper(
        top: (0.07, 0.10, 0.17), bottom: (0.06, 0.11, 0.14),
        glows: [Glow(x: 0.08, y: 0.25, rx: 0.55, ry: 0.80, rgb: (0.18, 0.30, 0.70), alpha: 0.65),
                Glow(x: 0.40, y: 0.95, rx: 0.60, ry: 0.60, rgb: (0.08, 0.52, 0.48), alpha: 0.60),
                Glow(x: 0.98, y: 0.72, rx: 0.42, ry: 0.65, rgb: (0.64, 0.28, 0.54), alpha: 0.55),
                Glow(x: 0.62, y: 0.12, rx: 0.40, ry: 0.35, rgb: (0.34, 0.24, 0.64), alpha: 0.50),
                Glow(x: 0.38, y: 0.50, rx: 0.35, ry: 0.40, rgb: (0.16, 0.24, 0.50), alpha: 0.40)])

    func view(size: NSSize) -> some View {
        // Drawn at quarter resolution and smoothly upscaled: the fields are
        // soft anyway, and full-resolution gradients triple the PNG size.
        Image(nsImage: image(size: size, scale: 0.25)).resizable().interpolation(.high)
            .frame(width: size.width, height: size.height)
    }

    func image(size: NSSize, scale: CGFloat) -> NSImage {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage(size: size) }
        let w = CGFloat(width), h = CGFloat(height)
        let color = { (rgb: (CGFloat, CGFloat, CGFloat), alpha: CGFloat) in CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha) }
        let base = CGGradient(colorsSpace: space, colors: [color(top, 1), color(bottom, 1)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(base, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        for glow in glows {
            let gradient = CGGradient(colorsSpace: space,
                                      colors: [color(glow.rgb, glow.alpha), color(glow.rgb, glow.alpha * 0.55),
                                               color(glow.rgb, glow.alpha * 0.18), color(glow.rgb, 0)] as CFArray,
                                      locations: [0, 0.35, 0.7, 1])!
            context.saveGState()
            // Unit circle scaled into an ellipse; CG's origin is bottom-left.
            context.translateBy(x: glow.x * w, y: (1 - glow.y) * h)
            context.scaleBy(x: glow.rx * w, y: glow.ry * h)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            context.restoreGState()
        }
        guard let cgImage = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cgImage, size: size)
    }
}
