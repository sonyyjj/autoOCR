import Vision
import CoreImage
import CoreVideo

/// OCR 전처리·인식 옵션 (사용자 설정으로 노출됨).
struct OCROptions {
    var languageCorrection: Bool = true   // 언어 보정 (고유명사·코드엔 끄는 게 유리)
    var contrast: Double = 1.12           // 대비 강화 (1.0 = 원본)
    var upscale: Bool = true              // 작은 글자 업스케일
    var binarize: Bool = false            // 고대비 흑백(이진화)
}

/// 인식 결과와 평균 신뢰도. 하이브리드가 여러 결과 중 최선을 고를 때 사용한다.
struct OCRResult {
    let text: String
    let confidence: Float   // 0…1, 글자 수 가중 평균
    static let empty = OCRResult(text: "", confidence: 0)
}

/// Vision 기반 텍스트 인식기.
/// 무거운 인식 작업은 전용 백그라운드 큐에서 수행하고, 결과만 async 로 돌려준다.
enum TextRecognizer {
    private static let queue = DispatchQueue(label: "com.srd.ocr", qos: .userInitiated)

    /// CVPixelBuffer는 Sendable이 아니므로, 백그라운드 큐로 안전하게 넘기기 위한 래퍼.
    private struct SendableBox<T>: @unchecked Sendable {
        let value: T
    }

    /// 단일 패스 인식.
    static func recognize(_ pixelBuffer: CVPixelBuffer,
                          languages: [String],
                          automatic: Bool,
                          options: OCROptions) async throws -> OCRResult {
        let box = SendableBox(value: pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try perform(box.value, languages: languages, automatic: automatic, options: options)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 하이브리드 인식: 여러 전처리 변형으로 인식한 뒤 신뢰도가 가장 높은 결과를 고른다.
    /// 외부 모델 없이 어려운 케이스(저대비·복잡한 배경)의 정확도를 끌어올린다.
    static func recognizeBest(_ pixelBuffer: CVPixelBuffer,
                              languages: [String],
                              automatic: Bool,
                              options: OCROptions) async throws -> OCRResult {
        let box = SendableBox(value: pixelBuffer)

        // 변형: (1) 사용자 설정 그대로 (2) 이진화 (3) 대비 강화
        var binarized = options; binarized.binarize = true
        var highContrast = options; highContrast.binarize = false
        highContrast.contrast = min(options.contrast + 0.25, 1.8)
        let variants = [options, binarized, highContrast]

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var best = OCRResult.empty
                for variant in variants {
                    guard let result = try? perform(box.value,
                                                    languages: languages,
                                                    automatic: automatic,
                                                    options: variant) else { continue }
                    if !result.text.isEmpty, result.confidence > best.confidence {
                        best = result
                    }
                }
                continuation.resume(returning: best)
            }
        }
    }

    // MARK: - 내부

    /// 큐 위에서 동기적으로 한 번 인식한다.
    private static func perform(_ pixelBuffer: CVPixelBuffer,
                                languages: [String],
                                automatic: Bool,
                                options: OCROptions) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = options.languageCorrection
        request.revision = VNRecognizeTextRequest.currentRevision
        if automatic {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }

        let image = preprocess(pixelBuffer, options: options)
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])

        // 관측 결과를 화면 위→아래 순서로 정렬한다. (boundingBox는 좌하단 원점이라 midY가 클수록 위)
        let observations = (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var lines: [(text: String, confidence: Float)] = observations.compactMap {
            guard let candidate = $0.topCandidates(1).first else { return nil }
            let cleaned = candidate.string
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            // 글자·숫자가 하나도 없는 줄(예: "!", "…")은 노이즈로 보고 버린다.
            guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return (cleaned, candidate.confidence)
        }

        // 저신뢰도 조각 제거 — 단, 전부 낮으면 원본을 유지(전멸 방지).
        let threshold: Float = 0.3
        let filtered = lines.filter { $0.confidence >= threshold }
        if !filtered.isEmpty { lines = filtered }

        let text = lines.map(\.text).joined(separator: "\n")

        // 글자 수로 가중한 평균 신뢰도
        let totalLength = lines.reduce(0) { $0 + $1.text.count }
        let confidence: Float = totalLength > 0
            ? lines.reduce(Float(0)) { $0 + $1.confidence * Float($1.text.count) } / Float(totalLength)
            : 0
        return OCRResult(text: text, confidence: confidence)
    }

    /// OCR 전 전처리. 옵션에 따라 업스케일 · 대비/회색조 · 이진화를 적용한다.
    private static func preprocess(_ pixelBuffer: CVPixelBuffer, options: OCROptions) -> CIImage {
        var image = CIImage(cvPixelBuffer: pixelBuffer)

        if options.upscale {
            let height = image.extent.height
            let targetHeight: CGFloat = 720
            if height > 0, height < targetHeight {
                let scale = min(targetHeight / height, 4.0)
                image = image.applyingFilter("CILanczosScaleTransform",
                                             parameters: [kCIInputScaleKey: scale,
                                                          kCIInputAspectRatioKey: 1.0])
            }
        }

        image = image.applyingFilter("CIColorControls",
                                     parameters: [kCIInputSaturationKey: 0.0,
                                                  kCIInputContrastKey: options.contrast,
                                                  kCIInputBrightnessKey: 0.0])

        // 작은 글자 윤곽을 또렷하게 (약하게 적용해 노이즈 증폭을 피함)
        image = image.applyingFilter("CIUnsharpMask",
                                     parameters: [kCIInputRadiusKey: 2.0,
                                                  kCIInputIntensityKey: 0.4])

        if options.binarize {
            image = image.applyingFilter("CIColorThresholdOtsu", parameters: [:])
        }

        return image
    }
}
