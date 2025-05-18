import CoreVideo

/// PaddleOCR(CoreML) 엔진 자리표시자 — 하이브리드 확장 지점.
///
/// 현재는 스텁이며, 실제 동작에는 아래 자산과 구현이 필요하다.
/// 준비되면 이 엔진의 `recognize`를 채우고, `TextRecognizer.recognizeBest`가
/// Vision 결과와 이 엔진의 결과를 신뢰도로 비교해 더 나은 쪽을 채택하도록 연결하면 된다.
///
/// # 완성 로드맵
/// 1. 모델 자산 (앱 번들에 포함, 약 10–30MB)
///    - 텍스트 검출:  PP-OCRv4 det  → CoreML (.mlpackage)
///    - (선택) 방향분류: PP-OCRv4 cls → CoreML
///    - 텍스트 인식:  PP-OCRv4 rec  → CoreML  + 문자 사전(ko/en dict .txt)
///    - 변환 파이프라인: paddle2onnx → onnx → coremltools
/// 2. 전처리
///    - 검출 입력: 정규화 + 크기 배수(32) 패딩
/// 3. 후처리
///    - 검출: DB(Differentiable Binarization) 후처리로 텍스트 박스 추출
///    - 인식: 각 박스 크롭 → rec 모델 → CTC 디코딩(사전 인덱스 → 문자)
/// 4. 결과를 `OCRResult(text:confidence:)`로 반환 (rec의 softmax 평균을 confidence로)
///
/// # 통합 지점
/// `HybridEngine` 프로토콜을 만들어 Vision/Paddle을 동일 인터페이스로 취급하고,
/// `recognizeBest`에서 두 엔진 결과 중 confidence가 높은 것을 고르면 된다.
enum PaddleOCREngine {
    /// 모델 자산이 번들에 포함되어 사용 가능한지 여부.
    static var isAvailable: Bool { false }

    /// 실제 구현 전까지는 빈 결과를 반환한다. (하이브리드가 Vision 결과로 폴백)
    static func recognize(_ pixelBuffer: CVPixelBuffer,
                          languages: [String]) async -> OCRResult {
        return .empty
    }
}
