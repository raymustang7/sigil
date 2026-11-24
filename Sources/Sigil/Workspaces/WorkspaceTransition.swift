import Cocoa

/// Full-display overlay shown while a workspace switch is in progress: a blurred, darkened mask
/// over the display with the target name and a five-dot loader. Fades in on show, out on dismiss.
final class WorkspaceTransition {
    private var window: NSWindow?
    private var dots: DotsLoader?

    static func screen(for display: WorkspaceDisplay) -> NSScreen? {
        NSScreen.screens.first { WorkspaceDisplays.key(for: $0) == display.key }
    }

    func show(on display: WorkspaceDisplay, title: String) {
        guard let screen = WorkspaceTransition.screen(for: display) else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.alphaValue = 0

        let size = screen.frame.size
        let root = NSView(frame: NSRect(origin: .zero, size: size))

        // Blur of whatever is behind the window, then a dark tint on top.
        let blur = NSVisualEffectView(frame: root.bounds)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.autoresizingMask = [.width, .height]
        root.addSubview(blur)

        let tint = NSView(frame: root.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        tint.autoresizingMask = [.width, .height]
        root.addSubview(tint)

        let label = NSTextField(labelWithString: "Switching to \(title)")
        label.font = .systemFont(ofSize: 32, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.alignment = .center
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (size.width - label.frame.width) / 2, y: size.height / 2 + 14)
        root.addSubview(label)

        let loader = DotsLoader(frame: NSRect(x: (size.width - DotsLoader.width) / 2, y: size.height / 2 - 40, width: DotsLoader.width, height: DotsLoader.height))
        root.addSubview(loader)

        w.contentView = root
        w.orderFrontRegardless()
        loader.start()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            w.animator().alphaValue = 1
        }
        window = w
        dots = loader
    }

    func dismiss() {
        guard let w = window else { return }
        let loader = dots
        window = nil
        dots = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 0
        }, completionHandler: {
            loader?.stop()
            w.orderOut(nil)
        })
    }
}

/// Five dots bouncing up and down in sequence.
final class DotsLoader: NSView {
    static let count = 5
    static let dot: CGFloat = 12
    static let gap: CGFloat = 12
    static let bounce: CGFloat = 14
    static var width: CGFloat { CGFloat(count) * dot + CGFloat(count - 1) * gap }
    static var height: CGFloat { dot + bounce * 2 }

    private var layers: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for i in 0..<DotsLoader.count {
            let l = CALayer()
            l.frame = CGRect(x: CGFloat(i) * (DotsLoader.dot + DotsLoader.gap), y: DotsLoader.bounce, width: DotsLoader.dot, height: DotsLoader.dot)
            l.cornerRadius = DotsLoader.dot / 2
            l.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            layer?.addSublayer(l)
            layers.append(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        for (i, l) in layers.enumerated() {
            let anim = CAKeyframeAnimation(keyPath: "position.y")
            let base = l.position.y
            anim.values = [base, base + DotsLoader.bounce, base]
            anim.keyTimes = [0, 0.5, 1]
            anim.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            anim.duration = 0.6
            anim.beginTime = CACurrentMediaTime() + Double(i) * 0.1
            anim.repeatCount = .infinity
            anim.repeatDuration = 0
            // Pause between bounces so the rhythm reads as a wave across the row.
            let group = CAAnimationGroup()
            group.animations = [anim]
            group.duration = 1.1
            group.beginTime = anim.beginTime
            anim.beginTime = 0
            group.repeatCount = .infinity
            l.add(group, forKey: "bounce")
        }
    }

    func stop() {
        layers.forEach { $0.removeAllAnimations() }
    }
}
