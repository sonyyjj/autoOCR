import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreVideo
import UniformTypeIdentifiers

/// 인식 언어 선택지.
enum RecognitionLanguage: String, CaseIterable, Identifiable {
    case koreanEnglish
    case english
    case japanese
    case chinese
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .koreanEnglish: return "한국어 + 영어"
        case .english:       return "영어"
        case .japanese:      return "일본어"
        case .chinese:       return "중국어"
        case .auto:          return "자동 감지"
        }
    }

    var visionLanguages: [String] {
        switch self {
        case .koreanEnglish: return ["ko-KR", "en-US"]
        case .english:       return ["en-US"]
        case .japanese:      return ["ja-JP"]
        case .chinese:       return ["zh-Hans", "zh-Hant"]
        case .auto:          return []
        }
    }

    var isAutomatic: Bool { self == .auto }
}

/// 화면 캡처와 OCR을 조율하는 상태 객체.
@MainActor
final class OCRManager: ObservableObject {
    // 표시 상태
    @Published private(set) var extractedText: String = ""
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var hasSelection: Bool = false
    @Published private(set) var selectionSize: CGSize?

    // 사용자 설정 (변경 시 자동 저장)
    static let intervalRange: ClosedRange<Double> = 0.5...60
    @Published var recognitionInterval: Double = 10.0 { didSet { persist() } }
    @Published var autoCopy: Bool = true              { didSet { persist() } }
    @Published var accumulate: Bool = true            { didSet { persist() } }
    // 누적 모드에서 완전히 동일한 자막 블록은 한 번만 남긴다.
    @Published var deduplicate: Bool = true           { didSet { persist() } }
    @Published var language: RecognitionLanguage = .koreanEnglish { didSet { persist() } }
    // 영역 선택 단축키. 기본 ⌘⇧0
    @Published var globalShortcut: KeyboardShortcutConfig? = .defaultRegionSelect {
        didSet { persist(); registerShortcuts() }
    }
    // 지금 캡처 단축키 (간격 무시하고 즉시 캡처). 기본 ⌘⇧9
    @Published var captureShortcut: KeyboardShortcutConfig? = .defaultCaptureNow {
        didSet { persist(); registerShortcuts() }
    }
    // 단축키 충돌 등 경고 메시지 (없으면 nil)
    @Published private(set) var shortcutWarning: String?

    // 캡션 미러(화면 하단 자막형 오버레이)
    @Published var captionOverlayEnabled: Bool = true {
        didSet {
            persist()
            if captionOverlayEnabled { captionMirror.setPinned(captionPinned) }
            else { captionMirror.hide() }
        }
    }
    @Published var captionPinned: Bool = false {
        didSet {
            persist()
            if captionOverlayEnabled { captionMirror.setPinned(captionPinned) }
        }
    }

    // OCR 전처리 파라미터
    @Published var languageCorrection: Bool = true { didSet { persist() } }
    @Published var ocrContrast: Double = 1.12      { didSet { persist() } }
    @Published var upscaleSmallText: Bool = true   { didSet { persist() } }
    @Published var binarize: Bool = false          { didSet { persist() } }
    // 하이브리드: 여러 전처리 변형으로 인식 후 신뢰도가 가장 높은 결과 채택 (느리지만 정확)
    @Published var hybridMode: Bool = false        { didSet { persist() } }

    private var ocrOptions: OCROptions {
        OCROptions(languageCorrection: languageCorrection,
                   contrast: ocrContrast,
                   upscale: upscaleSmallText,
                   binarize: binarize)
    }

    private let captureService = ScreenCaptureService()
    private let selectionController = RegionSelectionController()
    private let hotKeyManager = GlobalHotKeyManager()
    private let toast = ToastPresenter()
    private let captionMirror = CaptionMirror()

    // '지금 캡처'를 위해 가장 최근에 받은 프레임을 보관한다.
    private var latestBuffer: CVPixelBuffer?

    private var selectedRegion: CGRect?
    private var selectedDisplayID: CGDirectDisplayID?
    private var pixelScale: CGFloat = 2
    private var recognitionTask: Task<Void, Never>?

    // 전환(페이드) 프레임 방지용 정착 설정.
    // 화면이 settleDelay 동안 안 바뀌면 인식하되, 계속 바뀌어도(영상 등) 상한 시간이 지나면
    // 무조건 인식해 굶지 않도록 한다.
    private let settleDelay: TimeInterval = 0.4
    private let maxSettleWait: TimeInterval = 0.6

    // 누적 모드에서 직전에 추가한 블록 (연속 중복 방지용)
    private var lastBlock: String = ""
    // 누적 모드에서 지금까지 추가한 모든 블록 (완전 동일 중복 제거용)
    private var seenBlocks: Set<String> = []

    private var settingsLoaded = false

    var canCopy: Bool { !extractedText.isEmpty }

    init() {
        let defaults = UserDefaults.standard

        // 새 기본 단축키(⌘⇧0 / ⌘⇧9)를 기존 사용자에게도 한 번 적용한다.
        // (이후 사용자가 바꾼 값은 그대로 유지됨)
        if defaults.integer(forKey: Keys.shortcutMigration) < 1 {
            defaults.removeObject(forKey: Keys.shortcut)
            defaults.removeObject(forKey: Keys.captureShortcut)
            defaults.set(1, forKey: Keys.shortcutMigration)
        }

        if defaults.object(forKey: Keys.interval) != nil {
            recognitionInterval = defaults.double(forKey: Keys.interval)
        }
        if defaults.object(forKey: Keys.autoCopy) != nil {
            autoCopy = defaults.bool(forKey: Keys.autoCopy)
        }
        if defaults.object(forKey: Keys.accumulate) != nil {
            accumulate = defaults.bool(forKey: Keys.accumulate)
        }
        if defaults.object(forKey: Keys.deduplicate) != nil {
            deduplicate = defaults.bool(forKey: Keys.deduplicate)
        }
        if let raw = defaults.string(forKey: Keys.language),
           let lang = RecognitionLanguage(rawValue: raw) {
            language = lang
        }
        if let data = defaults.data(forKey: Keys.shortcut) {
            // 저장된 값이 있으면(빈 데이터 = 사용자가 해제한 경우 포함) 그대로 반영한다.
            globalShortcut = try? JSONDecoder().decode(KeyboardShortcutConfig.self, from: data)
        }
        if let data = defaults.data(forKey: Keys.captureShortcut) {
            captureShortcut = try? JSONDecoder().decode(KeyboardShortcutConfig.self, from: data)
        }
        if defaults.object(forKey: Keys.captionEnabled) != nil {
            captionOverlayEnabled = defaults.bool(forKey: Keys.captionEnabled)
        }
        if defaults.object(forKey: Keys.captionPinned) != nil {
            captionPinned = defaults.bool(forKey: Keys.captionPinned)
        }
        if defaults.object(forKey: Keys.languageCorrection) != nil {
            languageCorrection = defaults.bool(forKey: Keys.languageCorrection)
        }
        if defaults.object(forKey: Keys.contrast) != nil {
            ocrContrast = defaults.double(forKey: Keys.contrast)
        }
        if defaults.object(forKey: Keys.upscale) != nil {
            upscaleSmallText = defaults.bool(forKey: Keys.upscale)
        }
        if defaults.object(forKey: Keys.binarize) != nil {
            binarize = defaults.bool(forKey: Keys.binarize)
        }
        if defaults.object(forKey: Keys.hybrid) != nil {
            hybridMode = defaults.bool(forKey: Keys.hybrid)
        }
        settingsLoaded = true

        registerShortcuts()
        if captionOverlayEnabled { captionMirror.setPinned(captionPinned) }
    }

    /// 새로 지정하려는 단축키가 유효한지 검사한다. 문제가 있으면 안내 메시지를 반환(있으면 저장 차단).
    /// - Parameter forCaptureNow: true면 '지금 캡처' 슬롯, false면 '영역 선택' 슬롯.
    func validateShortcut(_ config: KeyboardShortcutConfig, forCaptureNow: Bool) -> String? {
        // 같은 슬롯에 동일 조합을 다시 지정하는 건 변화 없음 → 허용.
        let current = forCaptureNow ? captureShortcut : globalShortcut
        if let current, config.sameCombo(as: current) { return nil }

        // 다른 슬롯의 단축키와 충돌.
        let other = forCaptureNow ? globalShortcut : captureShortcut
        if let other, config.sameCombo(as: other) {
            let otherName = forCaptureNow ? "영역 선택" : "지금 캡처"
            return "‘\(otherName)’ 단축키와 같습니다. 다른 키를 선택하세요."
        }

        // 시스템/다른 앱이 이미 쓰는 조합.
        if !hotKeyManager.canRegister(config) {
            return "이미 다른 곳에서 사용 중인 단축키입니다. 다른 키를 선택하세요."
        }
        return nil
    }

    /// 두 전역 단축키(영역 선택 / 지금 캡처)를 등록하고 충돌을 검사한다.
    private func registerShortcuts() {
        let okRegion = hotKeyManager.register(id: 1, config: globalShortcut) { [weak self] in
            Task { @MainActor in await self?.selectRegion() }
        }
        let okCapture = hotKeyManager.register(id: 2, config: captureShortcut) { [weak self] in
            Task { @MainActor in await self?.captureNow() }
        }

        var warnings: [String] = []
        if let region = globalShortcut, let capture = captureShortcut, region.sameCombo(as: capture) {
            // 두 단축키가 같으면 하나만 등록되므로 명확히 안내한다.
            warnings.append("‘영역 선택’과 ‘지금 캡처’ 단축키가 \(region.displayString) 로 같습니다. 하나를 바꿔주세요.")
        } else {
            if globalShortcut != nil, !okRegion {
                warnings.append("‘영역 선택’ 단축키(\(globalShortcut!.displayString))가 다른 앱/시스템과 충돌합니다. 다른 조합을 사용해주세요.")
            }
            if captureShortcut != nil, !okCapture {
                warnings.append("‘지금 캡처’ 단축키(\(captureShortcut!.displayString))가 다른 앱/시스템과 충돌합니다. 다른 조합을 사용해주세요.")
            }
        }
        shortcutWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

    // MARK: - 영역 선택 (선택 후 자동으로 인식 시작)

    func selectRegion() async {
        if isCapturing { await stopCapturing(silent: true) }

        guard let result = await selectionController.selectRegion() else {
            statusMessage = "영역 선택이 취소되었습니다."
            return
        }
        selectedRegion = result.rect
        selectedDisplayID = result.displayID
        selectionSize = result.rect.size
        pixelScale = result.pixelScale
        hasSelection = true

        await startCapturing()
    }

    // MARK: - 캡처 제어

    func toggleCapturing() async {
        if isCapturing {
            await stopCapturing()
        } else {
            await startCapturing()
        }
    }

    func startCapturing() async {
        guard !isCapturing else { return }
        guard let region = selectedRegion else {
            statusMessage = "먼저 영역을 선택해주세요."
            return
        }

        // 실제 권한 판정: ScreenCaptureKit 콘텐츠 조회가 성공하면 권한이 있는 것이다.
        // (CGPreflightScreenCaptureAccess는 부여 직후/개발 서명에서 신뢰하기 어렵다.)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            await guidePermission()
            return
        }

        guard let display = display(for: selectedDisplayID, in: content) else {
            statusMessage = "캡처할 디스플레이를 찾을 수 없습니다."
            return
        }

        do {
            let frames = try await captureService.start(region: region,
                                                        display: display,
                                                        pixelScale: pixelScale)
            isCapturing = true
            statusMessage = "실시간 인식 중…"
            recognitionTask = Task { await consume(frames) }
        } catch {
            statusMessage = "캡처 시작 실패: \(error.localizedDescription)"
            await captureService.stop()
        }
    }

    func stopCapturing(silent: Bool = false) async {
        recognitionTask?.cancel()
        recognitionTask = nil
        latestBuffer = nil
        await captureService.stop()
        isCapturing = false
        isProcessing = false
        if !silent { statusMessage = "인식을 중지했습니다." }
    }

    /// 간격을 무시하고 지금 이 순간의 화면을 즉시 한 번 인식한다. (전역 단축키용)
    func captureNow() async {
        guard isCapturing, let pixelBuffer = latestBuffer else {
            statusMessage = "먼저 인식을 시작해주세요."
            return
        }
        isProcessing = true
        do {
            let result = hybridMode
                ? try await TextRecognizer.recognizeBest(pixelBuffer,
                                                         languages: language.visionLanguages,
                                                         automatic: language.isAutomatic,
                                                         options: ocrOptions)
                : try await TextRecognizer.recognize(pixelBuffer,
                                                     languages: language.visionLanguages,
                                                     automatic: language.isAutomatic,
                                                     options: ocrOptions)
            handleRecognized(result.text)
        } catch {
            statusMessage = "텍스트 인식 오류: \(error.localizedDescription)"
        }
        isProcessing = false
    }

    /// 캡처 프레임을 소비한다.
    /// 1) 주기(`recognitionInterval`)로 스로틀하고,
    /// 2) 직전 프레임과 화면이 같으면(지문 동일) OCR을 건너뛴다.
    /// 3) 전환 프레임 방지: 주기가 된 뒤에도 화면이 아직 바뀌는 중이면 잠깐(settleDelay) 정착을
    ///    기다린다. 단, 영상처럼 계속 바뀌어 정착하지 않아도 상한(maxSettleWait)이 지나면 무조건
    ///    인식해 굶지 않는다.
    private func consume(_ frames: AsyncStream<CVPixelBuffer>) async {
        var lastRun = Date.distantPast
        var lastFingerprint = 0
        var pendingFingerprint = 0
        var pendingSince = Date.distantPast

        for await pixelBuffer in frames {
            if Task.isCancelled { break }

            latestBuffer = pixelBuffer   // '지금 캡처'용 최신 프레임 보관

            let now = Date()
            guard now.timeIntervalSince(lastRun) >= recognitionInterval else { continue }

            let fingerprint = FrameFingerprint.compute(pixelBuffer)
            if fingerprint == lastFingerprint { continue }

            // 화면이 아직 바뀌는 중이면 정착 타이머를 리셋한다.
            if fingerprint != pendingFingerprint {
                pendingFingerprint = fingerprint
                pendingSince = now
            }
            let settled = now.timeIntervalSince(pendingSince) >= settleDelay
            let maxWaitReached = now.timeIntervalSince(lastRun) >= recognitionInterval + maxSettleWait
            // 정착했거나(정지 화면) 상한에 도달(영상)하면 인식, 아니면 다음 프레임을 기다린다.
            guard settled || maxWaitReached else { continue }

            lastFingerprint = fingerprint
            lastRun = now

            isProcessing = true
            do {
                let result = hybridMode
                    ? try await TextRecognizer.recognizeBest(pixelBuffer,
                                                             languages: language.visionLanguages,
                                                             automatic: language.isAutomatic,
                                                             options: ocrOptions)
                    : try await TextRecognizer.recognize(pixelBuffer,
                                                         languages: language.visionLanguages,
                                                         automatic: language.isAutomatic,
                                                         options: ocrOptions)
                if !Task.isCancelled {
                    handleRecognized(result.text)
                }
            } catch {
                statusMessage = "텍스트 인식 오류: \(error.localizedDescription)"
            }
            isProcessing = false
        }
        isProcessing = false
    }

    /// 인식된 텍스트를 누적 모드/교체 모드에 맞춰 반영한다.
    private func handleRecognized(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if accumulate {
            if deduplicate {
                // 이미 한 번 추가한 것과 완전히 동일한 블록이면(순서 무관) 건너뛴다.
                guard !seenBlocks.contains(trimmed) else { return }
            } else {
                // 최소한 연속으로 같은 자막이 반복되면 추가하지 않는다.
                guard trimmed != lastBlock else { return }
            }
            seenBlocks.insert(trimmed)
            lastBlock = trimmed
            extractedText = extractedText.isEmpty ? trimmed : extractedText + "\n\n" + trimmed
        } else {
            guard trimmed != extractedText else { return }
            extractedText = trimmed
        }

        // 캡션 미러(하단 자막형 오버레이)에 방금 캡처한 텍스트를 표시한다.
        if captionOverlayEnabled {
            captionMirror.update(trimmed, pinned: captionPinned)
        }

        // 자동 복사는 방금 인식된 블록만 복사해 클립보드 부담을 줄인다.
        if autoCopy {
            writeToPasteboard(trimmed)
            statusMessage = "자동 복사됨 · 실시간 인식 중…"
            toast.show("복사됨")
        }
    }

    /// 주어진 displayID(선택한 화면)에 해당하는 `SCDisplay`를 찾는다.
    private func display(for id: CGDirectDisplayID?, in content: SCShareableContent) -> SCDisplay? {
        if let id, let match = content.displays.first(where: { $0.displayID == id }) {
            return match
        }
        let mainID = CGMainDisplayID()
        return content.displays.first { $0.displayID == mainID } ?? content.displays.first
    }

    // MARK: - 텍스트 동작

    func clearText() {
        extractedText = ""
        lastBlock = ""
        seenBlocks.removeAll()
        statusMessage = ""
    }

    func copyToClipboard() {
        guard !extractedText.isEmpty else { return }
        writeToPasteboard(extractedText)
        statusMessage = "클립보드에 복사했습니다."
        toast.show("복사됨")
    }

    /// 인식 결과 전체를 텍스트 파일로 저장한다.
    func exportToFile() {
        guard !extractedText.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "OCR-메모.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try extractedText.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "파일로 저장했습니다."
        } catch {
            statusMessage = "저장 실패: \(error.localizedDescription)"
        }
    }

    private func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - 권한

    /// 권한이 없을 때 시스템 프롬프트를 띄우고 설정으로 안내한다.
    private func guidePermission() async {
        // 최초 1회 시스템 권한 프롬프트를 트리거한다.
        CGRequestScreenCaptureAccess()

        let alert = NSAlert()
        alert.messageText = "화면 녹화 권한이 필요합니다"
        alert.informativeText = """
        시스템 설정 › 개인정보 보호 및 보안 › 화면 기록에서 ‘autoOCR’을 켠 뒤, \
        앱을 완전히 종료했다가 다시 실행해주세요.

        목록에 이미 autoOCR이 있는데도 동작하지 않으면, 그 항목을 ‘－’로 삭제한 뒤 \
        다시 캡처를 시도해 새로 등록하세요.
        """
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "닫기")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        statusMessage = "화면 녹화 권한을 허용한 뒤 앱을 다시 실행해주세요."
    }

    // MARK: - 설정 저장

    private enum Keys {
        static let interval = "recognitionInterval"
        static let autoCopy = "autoCopy"
        static let accumulate = "accumulate"
        static let deduplicate = "deduplicate"
        static let language = "recognitionLanguage"
        static let shortcut = "globalShortcut"
        static let captureShortcut = "captureShortcut"
        static let shortcutMigration = "shortcutDefaultsMigration"
        static let captionEnabled = "captionOverlayEnabled"
        static let captionPinned = "captionPinned"
        static let languageCorrection = "ocrLanguageCorrection"
        static let contrast = "ocrContrast"
        static let upscale = "ocrUpscale"
        static let binarize = "ocrBinarize"
        static let hybrid = "ocrHybrid"
    }

    private func persist() {
        guard settingsLoaded else { return }
        let defaults = UserDefaults.standard
        defaults.set(recognitionInterval, forKey: Keys.interval)
        defaults.set(autoCopy, forKey: Keys.autoCopy)
        defaults.set(accumulate, forKey: Keys.accumulate)
        defaults.set(deduplicate, forKey: Keys.deduplicate)
        defaults.set(language.rawValue, forKey: Keys.language)
        // 단축키: 지정값은 JSON으로, 해제(nil)는 빈 데이터로 저장해 기본값이 되살아나지 않게 한다.
        let data = (try? JSONEncoder().encode(globalShortcut)) ?? Data()
        defaults.set(globalShortcut == nil ? Data() : data, forKey: Keys.shortcut)
        let captureData = (try? JSONEncoder().encode(captureShortcut)) ?? Data()
        defaults.set(captureShortcut == nil ? Data() : captureData, forKey: Keys.captureShortcut)
        defaults.set(captionOverlayEnabled, forKey: Keys.captionEnabled)
        defaults.set(captionPinned, forKey: Keys.captionPinned)
        defaults.set(languageCorrection, forKey: Keys.languageCorrection)
        defaults.set(ocrContrast, forKey: Keys.contrast)
        defaults.set(upscaleSmallText, forKey: Keys.upscale)
        defaults.set(binarize, forKey: Keys.binarize)
        defaults.set(hybridMode, forKey: Keys.hybrid)
    }
}
