import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// `SCStream`을 감싸 캡처된 프레임을 픽셀 버퍼의 async 스트림으로 전달한다.
///
/// 이 객체 자신이 `SCStreamOutput`이므로 OCRManager가 이 서비스를 강하게 참조하는 한
/// 스트림 출력 대상도 살아 있다. (별도 output 객체가 조기 해제되던 기존 버그를 제거)
final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.srd.capture.samples")

    // continuation은 샘플 큐(yield)와 메인 액터(start/stop) 양쪽에서 접근하므로 락으로 보호한다.
    private let lock = NSLock()
    private var _continuation: AsyncStream<CVPixelBuffer>.Continuation?

    private func setContinuation(_ value: AsyncStream<CVPixelBuffer>.Continuation?) {
        lock.lock(); defer { lock.unlock() }
        _continuation = value
    }

    private func withContinuation(_ body: (AsyncStream<CVPixelBuffer>.Continuation) -> Void) {
        lock.lock()
        let continuation = _continuation
        lock.unlock()
        if let continuation { body(continuation) }
    }

    /// 지정한 영역(top-left screen points)을 캡처하기 시작한다.
    /// - Returns: 완성된 프레임마다 픽셀 버퍼를 방출하는 async 스트림.
    func start(region: CGRect, display: SCDisplay, pixelScale: CGFloat) async throws -> AsyncStream<CVPixelBuffer> {
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.sourceRect = region                                   // screen points 단위
        config.width = max(1, Int(region.width * pixelScale))        // 출력 픽셀 크기
        config.height = max(1, Int(region.height * pixelScale))
        config.showsCursor = false
        config.queueDepth = 3
        // OCR은 어차피 프레임을 솎아내므로, 스트림 자체도 최대 2fps로 제한해 부하를 낮춘다.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        // 캡처 시작 전에 continuation을 설정해 초기 프레임 유실을 막는다.
        let frames = AsyncStream<CVPixelBuffer>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            setContinuation(continuation)
        }

        try await stream.startCapture()
        self.stream = stream
        return frames
    }

    func stop() async {
        withContinuation { $0.finish() }
        setContinuation(nil)
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              Self.isComplete(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        withContinuation { $0.yield(pixelBuffer) }
    }

    /// 프레임 상태가 `.complete`인지 확인한다. (빈/유휴 프레임 인식을 방지)
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else {
            // 상태 정보를 못 읽으면 일단 유효한 프레임으로 간주한다.
            return true
        }
        return status == .complete
    }
}
