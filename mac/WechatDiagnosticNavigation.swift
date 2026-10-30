import CoreGraphics

/// Diagnostics only: navigate the real app's visible Home → Discover → Scan
/// when a plus glyph cannot be verified. No product scanner routing uses this.
enum WechatDiagnosticNavigation {
    private static func tabs(_ words:[ScannerNavigationOCR.Text])->Bool {
        Set(words.filter{$0.rect.midY>1000 && ["微信","通讯录","发现","我"].contains($0.value)}.map(\.value)).count>=3
    }
    static func discoverTab(in words:[ScannerNavigationOCR.Text])->CGPoint? {
        guard tabs(words),words.contains(where:{ScannerNavigationOCR.isWechatTitle($0.value) && $0.rect.midY<260}),
              let tab=words.first(where:{$0.value=="发现" && $0.rect.midY>1000}) else{return nil}
        return CGPoint(x:tab.rect.midX/720,y:tab.rect.midY/1280)
    }
    /// A restored Discover page may hide Scan in the user's own settings.
    /// Return to its verified Home tab instead of guessing a missing row.
    static func homeTabFromDiscover(in words:[ScannerNavigationOCR.Text])->CGPoint? {
        guard tabs(words),words.contains(where:{$0.value=="发现" && $0.rect.midY<260}),
              words.contains(where:{$0.value=="朋友圈" && $0.rect.midY<1000}),
              let tab=words.first(where:{$0.value=="微信" && $0.rect.midY>1000}) else{return nil}
        return CGPoint(x:tab.rect.midX/720,y:tab.rect.midY/1280)
    }
    static func scanRow(in words:[ScannerNavigationOCR.Text])->CGPoint? {
        guard tabs(words),words.contains(where:{$0.value=="发现" && $0.rect.midY<260}) else{return nil}
        let landmarks=Set(words.filter{$0.rect.midY<1000 && ["朋友圈","视频号","小程序","看一看"].contains($0.value)}.map(\.value))
        guard landmarks.contains("朋友圈") || landmarks.count>=2,
              let scan=words.first(where:{$0.value.filter{!$0.isWhitespace}=="扫一扫" && $0.rect.midY>150 && $0.rect.midY<1000}) else{return nil}
        return CGPoint(x:scan.rect.midX/720,y:scan.rect.midY/1280)
    }
}
