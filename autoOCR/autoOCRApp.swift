import SwiftUI

// 메뉴바 상주 유틸리티. 하나의 OCRManager를 앱 전역에서 공유한다.
@main
struct autoOCRApp: App {
    @StateObject private var ocrManager = OCRManager()

    var body: some Scene {
        MenuBarExtra {
            ContentView(ocrManager: ocrManager)
        } label: {
            Image(systemName: ocrManager.isCapturing ? "record.circle" : "text.viewfinder")
        }
        .menuBarExtraStyle(.window)
    }
}
