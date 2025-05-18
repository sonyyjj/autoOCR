import SwiftUI

// 메뉴바에서 열리는 컴팩트 패널. 상태·로직은 OCRManager가 담당하고 여기서는 UI만 조립한다.
struct ContentView: View {
    @ObservedObject var ocrManager: OCRManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            actionRow
            resultCard
            settingsSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: - 헤더 + 상태

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(.tint)
            Text("autoOCR")
                .font(.headline)
            Spacer()
            StatusBadge(isCapturing: ocrManager.isCapturing,
                        isProcessing: ocrManager.isProcessing)
        }
    }

    // MARK: - 영역 선택 / 시작·중지

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await ocrManager.selectRegion() }
            } label: {
                Label("영역 선택", systemImage: "crop")
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .help("영역을 선택하면 곧바로 실시간 인식이 시작됩니다.")

            Button {
                Task { await ocrManager.toggleCapturing() }
            } label: {
                Label(ocrManager.isCapturing ? "중지" : "시작",
                      systemImage: ocrManager.isCapturing ? "stop.fill" : "play.fill")
                    .frame(minHeight: 30)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .tint(ocrManager.isCapturing ? .red : .green)
            .disabled(!ocrManager.hasSelection && !ocrManager.isCapturing)
        }
    }

    // MARK: - 인식 결과

    private var resultCard: some View {
        ScrollView {
            Text(ocrManager.extractedText.isEmpty
                 ? "영역을 선택하면 인식된 텍스트가 여기에 표시됩니다."
                 : ocrManager.extractedText)
                .font(.system(size: 13))
                .foregroundStyle(ocrManager.extractedText.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: 220)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            if !ocrManager.extractedText.isEmpty {
                Text("\(ocrManager.extractedText.count)자")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
    }

    // MARK: - 설정 (인식 주기 / 자동 복사)

    // 프리셋: 빠른 자막(0.5초) ~ 고정 슬라이드(30초)
    private let intervalPresets: [Double] = [0.5, 10, 30]

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("인식 주기")
                    .font(.subheadline)
                Spacer()
                Text(Self.format(ocrManager.recognitionInterval))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }

            // 0.5~60초의 넓은 범위를 다루기 위해 로그 스케일로 매핑한다.
            // (짧은 주기 쪽에 해상도가 더 실려 미세 조절이 쉽다.)
            Slider(value: logIntervalBinding,
                   in: log(OCRManager.intervalRange.lowerBound)...log(OCRManager.intervalRange.upperBound))

            HStack {
                Text("0.5초").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("60초").font(.caption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(intervalPresets, id: \.self) { preset in
                    Button(Self.format(preset)) {
                        ocrManager.recognitionInterval = preset
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(isSelected(preset) ? .accentColor : .secondary)
                }
            }

            Divider().padding(.vertical, 2)

            HStack {
                Text("인식 언어")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $ocrManager.language) {
                    ForEach(RecognitionLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            HStack(alignment: .top) {
                Text("영역 선택 단축키")
                    .font(.subheadline)
                Spacer()
                ShortcutRecorder(shortcut: $ocrManager.globalShortcut,
                                 validate: { ocrManager.validateShortcut($0, forCaptureNow: false) })
            }
            HStack(alignment: .top) {
                Text("지금 캡처 단축키")
                    .font(.subheadline)
                Spacer()
                ShortcutRecorder(shortcut: $ocrManager.captureShortcut,
                                 validate: { ocrManager.validateShortcut($0, forCaptureNow: true) })
            }
            Text("‘지금 캡처’는 간격을 무시하고 현재 화면을 즉시 한 번 캡처합니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let warning = ocrManager.shortcutWarning {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .foregroundStyle(.orange)
                }
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            Toggle(isOn: $ocrManager.captionOverlayEnabled) {
                Text("화면에 캡션 표시 (하단 자막)")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $ocrManager.captionPinned) {
                Text("캡션 항상 띄워두기")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!ocrManager.captionOverlayEnabled)

            Divider().padding(.vertical, 2)

            Toggle(isOn: $ocrManager.accumulate) {
                Text("누적 모드 (새 자막을 지우지 않고 이어붙임)")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $ocrManager.deduplicate) {
                Text("중복 자막 제거 (완전히 같은 문구는 한 번만)")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!ocrManager.accumulate)

            Toggle(isOn: $ocrManager.autoCopy) {
                Text("새 텍스트 자동 복사")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider().padding(.vertical, 2)

            ocrQualitySection
        }
    }

    // MARK: - OCR 품질 (전처리 파라미터)

    private var ocrQualitySection: some View {
        DisclosureGroup("OCR 품질 설정") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $ocrManager.hybridMode) {
                    Text("고품질 하이브리드 (여러 전처리 비교, 느림)")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $ocrManager.languageCorrection) {
                    Text("언어 보정 (고유명사·코드엔 끄기)")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $ocrManager.upscaleSmallText) {
                    Text("작은 글자 업스케일")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $ocrManager.binarize) {
                    Text("고대비 흑백 (반투명·복잡한 배경에 유리)")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack {
                    Text("대비")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f", ocrManager.ocrContrast))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $ocrManager.ocrContrast, in: 1.0...1.6, step: 0.02)
            }
            .padding(.top, 4)
        }
        .font(.subheadline)
    }

    /// 슬라이더는 로그 값을 다루고, 저장은 초 단위 실제 값으로 변환·스냅한다.
    private var logIntervalBinding: Binding<Double> {
        Binding(
            get: { log(ocrManager.recognitionInterval) },
            set: { ocrManager.recognitionInterval = Self.snap(exp($0)) }
        )
    }

    private func isSelected(_ preset: Double) -> Bool {
        abs(ocrManager.recognitionInterval - preset) < 0.01
    }

    /// 슬라이더에서 나온 연속 값을 사람이 쓰기 좋은 눈금으로 스냅한다.
    private static func snap(_ value: Double) -> Double {
        let snapped: Double
        switch value {
        case ..<1:   snapped = (value / 0.5).rounded() * 0.5   // 0.5, 1.0
        case ..<10:  snapped = value.rounded()                 // 1…10 정수
        default:     snapped = (value / 5).rounded() * 5       // 10, 15, … 60
        }
        return min(max(snapped, OCRManager.intervalRange.lowerBound), OCRManager.intervalRange.upperBound)
    }

    private static func format(_ value: Double) -> String {
        value < 1 ? String(format: "%.1f초", value) : "\(Int(value))초"
    }

    // MARK: - 하단 동작

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                ocrManager.copyToClipboard()
            } label: {
                Label("복사", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(!ocrManager.canCopy)
            .help("전체 결과를 클립보드에 복사 (⌘C)")

            Button {
                ocrManager.exportToFile()
            } label: {
                Label("저장", systemImage: "square.and.arrow.down")
            }
            .disabled(!ocrManager.canCopy)
            .help("결과를 텍스트 파일로 저장")

            Button {
                ocrManager.clearText()
            } label: {
                Label("지우기", systemImage: "trash")
            }
            .disabled(!ocrManager.canCopy)
            .help("결과 지우기")

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("종료", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("앱 종료 (⌘Q)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.iconOnly)
    }
}

/// 현재 상태를 색 점 + 라벨로 보여주는 배지.
private struct StatusBadge: View {
    let isCapturing: Bool
    let isProcessing: Bool

    private var color: Color {
        if !isCapturing { return .secondary }
        return isProcessing ? .orange : .green
    }

    private var label: String {
        if !isCapturing { return "대기" }
        return isProcessing ? "인식 처리 중" : "실시간 인식 중"
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
