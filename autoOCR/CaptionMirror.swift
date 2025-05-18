import SwiftUI
import AppKit

/// 화면 하단에 자막처럼 떠서 방금 캡처된 텍스트를 보여주는 플로팅 창.
/// - 띄워두기(pinned) ON: 항상 표시
/// - OFF: 캡처될 때마다 잠깐 표시 후 사라짐
/// 클릭이 통과(click-through)되어 영상 조작을 방해하지 않는다.
@MainActor
final class CaptionMirror {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var pinned = false
    private var lastText = ""

    private let autoHideDelay: TimeInterval = 5

    /// 새 캡처 텍스트를 표시한다.
    func update(_ text: String, pinned: Bool) {
        self.pinned = pinned
        lastText = text
        present(text)
        if pinned {
            hideWorkItem?.cancel()
            hideWorkItem = nil
        } else {
            scheduleHide(after: autoHideDelay)
        }
    }

    /// 띄워두기 상태를 바꾼다.
    func setPinned(_ pinned: Bool) {
        self.pinned = pinned
        if pinned {
            present(lastText.isEmpty ? "캡처된 자막이 여기에 표시됩니다" : lastText)
            hideWorkItem?.cancel()
            hideWorkItem = nil
        } else {
            scheduleHide(after: 1.0)
        }
    }

    /// 즉시 숨긴다. (오버레이 비활성화 시)
    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        fadeOut()
    }

    // MARK: - 표시

    private func present(_ text: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let screen = screenUnderMouse()
        let maxWidth = min((screen?.frame.width ?? 1200) * 0.7, 900)
        if let hosting = panel.contentView as? NSHostingView<CaptionView> {
            hosting.rootView = CaptionView(text: text, maxWidth: maxWidth)
        }
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        position(panel, on: screen)

        if panel.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    // MARK: - 창/위치

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true          // 클릭 통과 (영상 조작 방해 안 함)
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CaptionView(text: "", maxWidth: 900))
        return panel
    }

    /// 화면 하단 중앙(영상 컨트롤 위쪽)에 배치한다.
    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        guard let frame = screen?.frame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + frame.height * 0.13   // 바닥에서 살짝 위 (자막 위치)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}

/// 자막 스타일 텍스트 뷰.
private struct CaptionView: View {
    let text: String
    let maxWidth: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .truncationMode(.tail)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: maxWidth)
            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
            .fixedSize(horizontal: false, vertical: true)
    }
}
