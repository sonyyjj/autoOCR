import CoreVideo

/// 픽셀 버퍼의 값싼 지문(해시)을 계산한다.
/// 연속한 프레임의 지문이 같으면 화면이 그대로라는 뜻이므로 OCR을 건너뛸 수 있다.
///
/// 전체 픽셀을 훑지 않고 일부 행/바이트만 표본으로 해싱해 비용을 최소화한다.
/// (같은 실행(run) 안에서만 비교하므로 Hasher의 실행별 시드는 문제되지 않는다.)
enum FrameFingerprint {
    static func compute(_ pixelBuffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var hasher = Hasher()
        hasher.combine(height)
        hasher.combine(bytesPerRow)

        // 균등 표본으로 행을 고르되, 각 행은 폭 전체를 해싱한다.
        // (일부 열만 해싱하면 넓은 자막의 오른쪽 변경을 놓칠 수 있어 폭 전체를 본다.)
        let sampleRowCount = min(height, 64)
        let step = max(1, height / sampleRowCount)

        var y = 0
        while y < height {
            let rowPtr = base.advanced(by: y * bytesPerRow)
            hasher.combine(bytes: UnsafeRawBufferPointer(start: rowPtr, count: bytesPerRow))
            y += step
        }
        return hasher.finalize()
    }
}
