import AppKit

/// 面板边缘的彩虹跑马灯。
///
/// 做法：把一整块圆锥渐变铺满面板，再让内层（`scrim`）四周内缩几个点压在上面 ——
/// 露出来的那一圈就是边框。比起「用蒙版把渐变裁成环」，这个做法不需要任何路径数学，
/// 也不会因为坐标系（翻转的父视图 / 图层的 frame 与 bounds）算错而画歪。
///
/// 转起来则交给 Core Animation：让渐变图层绕中心匀速自转，环上的颜色就沿边框跑，
/// 全程在 GPU 上，CPU 占用为零，也不需要定时器（对比逐帧重绘的跑马灯）。
final class RainbowBorderView: NSView {
    private let gradient = CAGradientLayer()

    /// 转一圈的秒数。
    var revolution: Double = 3.2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        gradient.type = .conic
        gradient.colors = Self.rainbow()
        gradient.locations = Self.rainbowLocations
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.masksToBounds = false
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { nil }

    /// 边框的圆角：要和外层容器一致，由使用方设置。
    var cornerRadius: CGFloat = 20 {
        didSet {
            layer?.cornerRadius = cornerRadius
            needsLayout = true
        }
    }

    private static func rainbow() -> [CGColor] {
        // 色相环上的 9 个采样点，首尾都是 0 以便无缝衔接。
        [0.0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1.0].map { hue in
            NSColor(hue: CGFloat(hue), saturation: 0.95, brightness: 1.0, alpha: 1.0).cgColor
        }
    }

    private static let rainbowLocations: [NSNumber] = {
        let count = 9
        return (0..<count).map { NSNumber(value: Double($0) / Double(count - 1)) }
    }()

    override func layout() {
        super.layout()
        layer?.cornerRadius = cornerRadius
        guard bounds.width > 0, bounds.height > 0 else { return }

        // 外接正方形：自转过程中任何角度都能盖满整个面板。
        let side = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot() * 1.02
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        CATransaction.commit()
    }

    /// 开始跑马灯。重复调用不会叠加动画。
    func start() {
        guard gradient.animation(forKey: "quickask.marquee") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = revolution
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        gradient.add(spin, forKey: "quickask.marquee")
    }

    func stop() {
        gradient.removeAnimation(forKey: "quickask.marquee")
    }
}
