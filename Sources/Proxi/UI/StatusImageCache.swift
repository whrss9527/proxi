import AppKit

/// 缓存依据是实际显示内容；完整网速仍可单独更新提示，不触发 CoreText 排版。
struct StatusImageKey: Equatable {
    var state: StatusIconState
    var upload: String?
    var download: String?
    var layout: SpeedLayout
    var textColor: CGColor
    var appearance: String
}

struct StatusImageCache<Image> {
    private var key: StatusImageKey?
    private var value: Image?

    mutating func image(for key: StatusImageKey, make: () -> Image) -> Image {
        if self.key == key, let value { return value }
        let image = make()
        self.key = key
        value = image
        return image
    }
}
