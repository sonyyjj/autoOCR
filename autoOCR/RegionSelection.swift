import AppKit

/// 영역 선택 결과. sourceRect에 바로 쓸 수 있는 값들을 담는다.
struct RegionSelectionResult {
    let rect: CGRect                  // 디스플레이 기준 top-left screen points
    let displayID: CGDirectDisplayID  // 선택이 이뤄진 화면
    let pixelScale: CGFloat           // 해당 화면의 backingScaleFactor
}

/// 전체 화면 오버레이를 띄워 사용자가 사각형 영역을 드래그로 선택하게 한다.
@MainActor
final class RegionSelectionController {
    private var window: SelectionWindow?

    /// 마우스가 있는 화면에 오버레이를 띄우고 선택 결과를 반환한다. 취소 시 nil.
    func selectRegion() async -> RegionSelectionResult? {
        // 캡처할 화면을 가리지 않도록 메뉴바 패널을 먼저 닫는다.
        dismissMenuBarPanel()
        // 패널이 사라지고 화면이 정리될 짧은 시간을 준 뒤 오버레이를 띄운다.
        try? await Task.sleep(nanoseconds: 150_000_000)

        return await withCheckedContinuation { continuation in
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let window = SelectionWindow(screen: screen) { [weak self] result in
                self?.window = nil
                continuation.resume(returning: result)
            }
            self.window = window
            window.present()
        }
    }

    /// 열려 있는 MenuBarExtra 패널을 닫는다.
    private func dismissMenuBarPanel() {
        // 패널이 열려 있으면 그 창이 key window이므로 숨긴다. (다음 클릭 시 다시 열림)
        NSApp.keyWindow?.orderOut(nil)
    }
}

/// 드래그로 영역을 선택받는 반투명 전체 화면 창.
final class SelectionWindow: NSWindow {
    fileprivate var startPoint: NSPoint?
    fileprivate var endPoint: NSPoint?

    private let targetScreen: NSScreen?
    private var completion: ((RegionSelectionResult?) -> Void)?
    private var hasCompleted = false

    init(screen: NSScreen?, completion: @escaping (RegionSelectionResult?) -> Void) {
        self.targetScreen = screen
        let frame = screen?.frame ?? NSScreen.main?.frame ?? .zero
        super.init(contentRect: frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        self.completion = completion
        // 프로그램적으로 만든 NSWindow는 close() 시 스스로 해제되어 ARC와 이중 해제로 크래시가 난다.
        // ARC가 생명주기를 관리하도록 자동 해제를 끈다.
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.3)
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = SelectionOverlayView(frame: CGRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { true }

    func present() {
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 마우스 / 키보드

    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
        endPoint = startPoint
        contentView?.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        endPoint = event.locationInWindow
        contentView?.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        finish(with: selectionResult())
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            finish(with: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - 좌표 변환

    /// 창 좌표(bottom-left, points) → 디스플레이 기준 화면 좌표(top-left, points).
    private func selectionResult() -> RegionSelectionResult? {
        guard let start = startPoint, let end = endPoint else { return nil }

        let rect = NSRect(x: min(start.x, end.x),
                          y: min(start.y, end.y),
                          width: abs(end.x - start.x),
                          height: abs(end.y - start.y))
        guard rect.width >= 1, rect.height >= 1 else { return nil }

        let screen = targetScreen ?? NSScreen.main
        let screenHeight = screen?.frame.height ?? 0
        let topLeft = CGRect(x: rect.minX,
                             y: screenHeight - rect.maxY,
                             width: rect.width,
                             height: rect.height)

        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
        let scale = screen?.backingScaleFactor ?? 2

        return RegionSelectionResult(rect: topLeft, displayID: displayID, pixelScale: scale)
    }

    private func finish(with result: RegionSelectionResult?) {
        guard !hasCompleted else { return }
        hasCompleted = true
        let completion = self.completion
        self.completion = nil
        close()
        completion?(result)
    }
}

/// 안내 문구, 선택 사각형, 크기 라벨을 그리는 오버레이 뷰.
private final class SelectionOverlayView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var sublayers: [CALayer] = [instructionLayer(scale: scale)]

        if let window = window as? SelectionWindow,
           let start = window.startPoint,
           let end = window.endPoint {
            let rect = NSRect(x: min(start.x, end.x),
                              y: min(start.y, end.y),
                              width: abs(end.x - start.x),
                              height: abs(end.y - start.y))

            let selectionLayer = CALayer()
            selectionLayer.frame = rect
            selectionLayer.borderColor = NSColor.systemRed.cgColor
            selectionLayer.borderWidth = 2.0
            sublayers.append(selectionLayer)

            let infoLayer = CATextLayer()
            infoLayer.string = "크기: \(Int(rect.width)) × \(Int(rect.height))"
            infoLayer.fontSize = 12
            infoLayer.foregroundColor = NSColor.white.cgColor
            infoLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
            infoLayer.cornerRadius = 4
            infoLayer.alignmentMode = .center
            infoLayer.frame = CGRect(x: rect.minX, y: rect.maxY + 5, width: 130, height: 20)
            infoLayer.contentsScale = scale
            sublayers.append(infoLayer)
        }

        layer.sublayers = sublayers
    }

    /// 화면 상단 중앙에 사용 안내를 표시한다.
    private func instructionLayer(scale: CGFloat) -> CALayer {
        let text = CATextLayer()
        text.string = "드래그하여 캡처할 영역을 선택하세요   ·   ESC 로 취소"
        text.fontSize = 15
        text.foregroundColor = NSColor.white.cgColor
        text.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        text.cornerRadius = 8
        text.alignmentMode = .center
        text.contentsScale = scale
        let width: CGFloat = 460
        let height: CGFloat = 34
        text.frame = CGRect(x: (bounds.width - width) / 2,
                            y: bounds.height - 120,
                            width: width,
                            height: height)
        return text
    }
}
