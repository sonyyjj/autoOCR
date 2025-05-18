import SwiftUI
import AppKit
import Carbon

/// 사용자 지정 전역 단축키 설정. UserDefaults에 JSON으로 저장된다.
struct KeyboardShortcutConfig: Codable, Equatable {
    var keyCode: UInt32
    var modifierFlags: UInt   // NSEvent.ModifierFlags.rawValue
    var keyLabel: String      // 표시용 문자 (예: "R", "Space")

    /// 기본 영역 선택 단축키: ⌘⇧0
    static let defaultRegionSelect = KeyboardShortcutConfig(
        keyCode: 29,
        modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue,
        keyLabel: "0"
    )

    /// 기본 지금 캡처 단축키: ⌘⇧9
    static let defaultCaptureNow = KeyboardShortcutConfig(
        keyCode: 25,
        modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue,
        keyLabel: "9"
    )

    private var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    /// 표시용 라벨을 제외한 실제 키 조합이 같은지.
    func sameCombo(as other: KeyboardShortcutConfig) -> Bool {
        keyCode == other.keyCode && modifierFlags == other.modifierFlags
    }

    var displayString: String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option)  { symbols += "⌥" }
        if flags.contains(.shift)   { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols + keyLabel
    }

    /// Carbon RegisterEventHotKey용 수정자 마스크.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        return mask
    }
}

/// Carbon 기반 전역 단축키 등록 관리자. 여러 개의 단축키를 id로 구분해 관리한다.
/// (Accessibility 권한이 필요 없고 App Store에서도 허용되는 방식)
final class GlobalHotKeyManager {
    private var handlerRef: EventHandlerRef?
    private var entries: [UInt32: (ref: EventHotKeyRef?, action: () -> Void)] = [:]
    private let signature: OSType = 0x53524448 // 'SRDH'

    init() {
        installHandler()
    }

    deinit {
        for entry in entries.values {
            if let ref = entry.ref { UnregisterEventHotKey(ref) }
        }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// id별로 단축키를 (재)등록한다. config가 nil이면 해당 id를 해제한다.
    /// - Returns: 등록 성공 여부. (이미 사용 중인 조합이면 실패)
    @discardableResult
    func register(id: UInt32, config: KeyboardShortcutConfig?, action: @escaping () -> Void) -> Bool {
        if let existing = entries[id]?.ref { UnregisterEventHotKey(existing) }
        entries[id] = nil

        guard let config else { return true }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(config.keyCode,
                                         config.carbonModifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else { return false }
        entries[id] = (ref, action)
        return true
    }

    fileprivate func handle(id: UInt32) {
        entries[id]?.action()
    }

    /// 해당 조합을 지금 등록할 수 있는지 시험한다. (임시 등록 후 즉시 해제)
    /// 시스템/다른 앱이 이미 사용 중이면 false.
    func canRegister(_ config: KeyboardShortcutConfig) -> Bool {
        var ref: EventHotKeyRef?
        let testID = EventHotKeyID(signature: signature, id: 9999)
        let status = RegisterEventHotKey(config.keyCode,
                                         config.carbonModifiers,
                                         testID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if status == noErr, let ref {
            UnregisterEventHotKey(ref)
            return true
        }
        return false
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            if status == noErr {
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handle(id: hotKeyID.id)
            }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)
    }
}

/// 클릭하면 다음 키 조합을 녹화해 전역 단축키로 지정하는 컨트롤.
/// `validate`가 안내 메시지를 반환하면 그 조합은 저장하지 않고 거부한다.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyboardShortcutConfig?
    var validate: ((KeyboardShortcutConfig) -> String?)? = nil

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button(action: toggle) {
                Text(label)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .tint(rejection != nil ? .orange : (isRecording ? .accentColor : .secondary))

            if let rejection {
                Text(rejection)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if isRecording { return "키 입력…" }
        return shortcut?.displayString ?? "설정 안 됨"
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        rejection = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // 녹화 중 키 입력은 앱으로 전달하지 않는다.
        }
    }

    private func handle(_ event: NSEvent) {
        // ESC: 취소
        if event.keyCode == 53 {
            stop()
            return
        }
        // Delete/Backspace: 지정 해제
        if event.keyCode == 51 {
            shortcut = nil
            stop()
            return
        }

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // 일반 키는 최소 하나의 수정자를 요구한다. (F1~F12는 단독 허용)
        guard Self.isFunctionKey(event.keyCode) || !mods.isEmpty else { return }

        let config = KeyboardShortcutConfig(keyCode: UInt32(event.keyCode),
                                            modifierFlags: mods.rawValue,
                                            keyLabel: Self.label(for: event))

        // 충돌 등으로 거부되면 저장하지 않고 안내한다.
        if let message = validate?(config) {
            rejection = message
            stop()
            return
        }

        shortcut = config
        rejection = nil
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    // MARK: - 키 표시 매핑

    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    private static func isFunctionKey(_ code: UInt16) -> Bool { functionKeys.contains(code) }

    private static func label(for event: NSEvent) -> String {
        let specials: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        if let special = specials[event.keyCode] { return special }
        if let chars = event.charactersIgnoringModifiers,
           let first = chars.first,
           first.isLetter || first.isNumber || "`-=[]\\;',./".contains(first) {
            return String(first).uppercased()
        }
        return "Key \(event.keyCode)"
    }
}
