import SwiftUI
import AppKit

/// 복사 등 순간 피드백을 화면 상단 중앙에 부드럽게 띄웠다 사라지게 하는 HUD.
/// 포커스를 뺏지 않고(non-activating) 클릭도 통과시켜(non-interactive) 시청을 방해하지 않는다.
@MainActor
final class ToastPresenter {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(_ message: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        if let hosting = panel.contentView as? NSHostingView<ToastView> {
            hosting.rootView = ToastView(message: message)
        }
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        position(panel)

        // 이미 떠 있으면 사라지는 타이머만 리셋(깜빡임 없이 유지).
        hideWorkItem?.cancel()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 전체화면(예: 유튜브 전체화면) 위에도 표시되도록.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ToastView(message: ""))
        return panel
    }

    /// 마우스가 있는 화면의 상단 중앙(메뉴바 아래)에 배치한다.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height - 56
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }
}

/// 토스트 내용 뷰. 반투명 캡슐 + 체크 아이콘.
private struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .fixedSize()
    }
}
