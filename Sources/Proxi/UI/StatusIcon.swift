import AppKit
import CoreText
import SwiftUI

/// 网速和开关怎么摆。
enum SpeedLayout: Equatable {
    /// 网速在左，开关在右。
    case speedLeft
    /// 开关在左，网速在右。
    case speedRight
    /// 只有网速，没有开关。
    case speedOnly

    /// 按设置和当前状态决定。「关代理时只显示网速」开着代理（或者系统代理被别的程序设置、代理服务器连不上）时
    /// 开关出现在网速左边：菜单栏图标是靠右排的，开关加在左边，网速本身的位置不动。
    static func resolve(side: SpeedSide, state: StatusIconState) -> SpeedLayout {
        switch side {
        case .left: return .speedLeft
        case .right: return .speedRight
        case .speedOnly: return state == .off ? .speedOnly : .speedRight
        }
    }
}

/// 菜单栏图标的状态。
enum StatusIconState: Equatable {
    case off
    case on(NSColor)
    case external
    case warning(NSColor)
    case error
}

/// 比较屏幕上真正显示的字样和外观，避免原始字节数略变就重新排版、提交菜单栏图像。
struct StatusImageInput: Equatable {
    var state: StatusIconState
    var upload: String?
    var download: String?
    var textColor: CGColor?
    var layout: SpeedLayout = .speedLeft
    var appearance: String
}

@MainActor
final class StatusImageUpdates {
    private var previous: StatusImageInput?

    func imageIfChanged(_ input: StatusImageInput) -> NSImage? {
        guard input != previous else { return nil }
        previous = input
        if let upload = input.upload, let download = input.download, let color = input.textColor {
            return StatusIcon.image(for: input.state, upload: upload, download: download, textColor: color, layout: input.layout)
        }
        return StatusIcon.image(for: input.state)
    }
}

/// 菜单栏图标：一个“开关”造型，圆角轨道加圆形滑块，滑块在右表示开启。关闭时是模板图，跟随菜单栏的深浅色。
/// 显示网速时把开关和两行小字合成一张图：按钮自己排版多行标题会让文字偏上，合成后两行文字的墨迹以开关的中线为中心。
enum StatusIcon {
    static let amber = NSColor(red: 0xd9 / 255, green: 0x77 / 255, blue: 0x06 / 255, alpha: 1)
    static let red = NSColor(red: 0xdc / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1)

    static let iconSize = NSSize(width: 24, height: 14)
    /// 网速的字体：等宽数字，宽度稳定，图标不会跟着抖。
    static let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
    /// 两行网速基线之间的距离。
    static let speedLinePitch: CGFloat = 9.5
    /// 开关和文字之间的间距。
    static let speedGap: CGFloat = 2
    /// 带网速时整张图的高度（两行 8.5 号字刚好放下，菜单栏里也放得下）。
    static let speedHeight: CGFloat = 20

    static func image(for state: StatusIconState) -> NSImage {
        let image = NSImage(size: iconSize, flipped: false) { rect in
            draw(state, in: rect)
            return true
        }
        image.isTemplate = state == .off
        return image
    }

    /// 箭头和数字之间的间距。
    static let arrowGap: CGFloat = 1.5

    /// 数字一栏的宽度：3 位数字加小数点再加最宽的单位。网速的数字固定 3 位，数值怎么变都放得下，
    /// 开关不会跟着左右跳，数字后面也只剩一两个点的空隙。
    static let valueColumnWidth: CGFloat = {
        let samples = ["0.00", "00.0", "000"].flatMap { number in ["B", "K", "M", "G"].map { number + $0 } }
        return ceil(samples.map { width(makeLine($0)) }.max() ?? 0)
    }()

    /// 开关加两行网速（上行、下行），网速在开关的左边、右边，或者只有网速。箭头单独占一列，数字紧跟在箭头后面：两个箭头上下对齐，
    /// 箭头和数字之间不空出一截；数字固定 3 位，数字一栏只比实际的字宽一点点，开关紧挨着文字。
    /// textColor 是网速文字的颜色（菜单栏文字色，或者跟着代理状态的颜色）；关闭状态是模板图，颜色由系统决定。
    static func image(for state: StatusIconState, upload: String, download: String, textColor: CGColor, layout: SpeedLayout = .speedLeft) -> NSImage {
        let arrows = [makeLine("↑"), makeLine("↓")]
        let values = [makeLine(trimmed(upload)), makeLine(trimmed(download))]
        let arrowWidth = ceil(arrows.map { width($0) }.max() ?? 0)
        let valueWidth = max(valueColumnWidth, ceil(values.map { width($0) }.max() ?? 0))
        let textWidth = arrowWidth + arrowGap + valueWidth
        let switchWidth = layout == .speedOnly ? 0 : speedGap + iconSize.width
        let size = NSSize(width: textWidth + switchWidth, height: speedHeight)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let textLeft = layout == .speedRight ? rect.minX + iconSize.width + speedGap : rect.minX
            if layout != .speedOnly {
                let iconX = layout == .speedLeft ? rect.maxX - iconSize.width : rect.minX
                let iconRect = NSRect(x: iconX, y: rect.midY - iconSize.height / 2, width: iconSize.width, height: iconSize.height)
                draw(state, in: iconRect)
            }
            // 文字：先量出两行（箭头加数字）的墨迹范围，让墨迹的整体中线正好落在开关的中线上，不依赖字体的名义行高。
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = .zero
            let topInk = max(CTLineGetImageBounds(arrows[0], context).maxY, CTLineGetImageBounds(values[0], context).maxY)
            let bottomInk = min(CTLineGetImageBounds(arrows[1], context).minY, CTLineGetImageBounds(values[1], context).minY)
            let bottomBaseline = rect.midY - (speedLinePitch + topInk + bottomInk) / 2
            let baselines = [bottomBaseline + speedLinePitch, bottomBaseline]
            context.setFillColor(state == .off ? NSColor.black.cgColor : textColor)
            for index in 0..<2 {
                context.textPosition = CGPoint(x: textLeft, y: baselines[index])
                CTLineDraw(arrows[index], context)
                context.textPosition = CGPoint(x: textLeft + arrowWidth + arrowGap, y: baselines[index])
                CTLineDraw(values[index], context)
            }
            context.restoreGState()
            return true
        }
        image.isTemplate = state == .off
        return image
    }

    /// 网速文字跟着代理状态时的颜色：开着用开关的颜色，系统代理被别的程序设置时黄色，代理服务器连不上时红色；关着时返回 nil（用普通的菜单栏文字色）。
    /// 开关的颜色直接当小字用对比度不够，按菜单栏深浅自动调深或调浅到 4.5:1 以上。
    static func speedTextColor(for state: StatusIconState, darkMenuBar: Bool) -> NSColor? {
        let accent: NSColor
        switch state {
        case .off: return nil
        case .on(let color): accent = color
        case .external: accent = amber
        case .warning, .error: accent = red
        }
        return accent.legible(onDark: darkMenuBar)
    }

    private static func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// 去掉补位用的空格（普通空格和数字宽度的空格）。
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \u{2007}"))
    }

    private static func makeLine(_ text: String) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: speedFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
    }

    /// 把图渲染成位图（测试里检查对齐用）。
    static func bitmap(of image: NSImage, scale: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        return rep
    }

    private static func draw(_ state: StatusIconState, in rect: NSRect) {
        // 关闭状态用 destinationOut 挖空滑块，画完要把合成模式恢复，后面的文字才能正常画上去。
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        let track = rect.insetBy(dx: 0.5, dy: 0.5)
        let radius = track.height / 2
        let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        let knobInset: CGFloat = 2.5
        let knobDiameter = track.height - knobInset * 2
        func knobRect(right: Bool) -> NSRect {
            let x = right ? track.maxX - knobInset - knobDiameter : track.minX + knobInset
            return NSRect(x: x, y: track.minY + knobInset, width: knobDiameter, height: knobDiameter)
        }
        switch state {
        case .off:
            NSColor.black.setFill()
            trackPath.fill()
            // 模板图只看透明度：把滑块“挖空”，得到一个空心的滑块。
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: knobRect(right: false)).fill()
        case .on(let color):
            color.setFill()
            trackPath.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect(right: true)).fill()
        case .external:
            amber.setFill()
            trackPath.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect(right: true)).fill()
        case .warning(let color):
            color.setFill()
            trackPath.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect(right: true)).fill()
            red.setFill()
            NSBezierPath(ovalIn: knobRect(right: true).insetBy(dx: 1.5, dy: 1.5)).fill()
        case .error:
            red.setFill()
            trackPath.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect(right: false)).fill()
        }
    }
}

extension NSColor {
    /// 估计的菜单栏底色（半透明，随桌面变化；取偏不利的一端）。
    static let lightMenuBarBackground = NSColor(srgbRed: 0.86, green: 0.86, blue: 0.86, alpha: 1)
    static let darkMenuBarBackground = NSColor(srgbRed: 0.23, green: 0.23, blue: 0.23, alpha: 1)

    /// 相对亮度（WCAG 的算法）。
    var relativeLuminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    /// 两个颜色的对比度（1…21）。
    static func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let a = first.relativeLuminance
        let b = second.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// 同一个色相、和菜单栏底色对比度够的版本：浅色菜单栏上往黑调，深色菜单栏上往白调，每次 5%，调到够为止。
    func legible(onDark dark: Bool, minimumContrast: CGFloat = 4.5) -> NSColor {
        guard let base = usingColorSpace(.sRGB) else { return self }
        let background: NSColor = dark ? .darkMenuBarBackground : .lightMenuBarBackground
        let target: NSColor = dark ? .white : .black
        var fraction: CGFloat = 0
        while fraction < 1 {
            let candidate = base.blended(withFraction: fraction, of: target)?.usingColorSpace(.sRGB) ?? base
            if NSColor.contrast(candidate, background) >= minimumContrast {
                return candidate
            }
            fraction += 0.05
        }
        return target
    }

    /// 解析 #rrggbb。
    convenience init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: text).scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }
}
