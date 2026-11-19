import SwiftUI

enum TickerTypography {
    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "Courier-Bold" : "Courier", fixedSize: size + 1)
    }

    /// Explicit runs keep Chinese in its existing system face rather than
    /// relying on Courier's CJK fallback (which can choose a different font).
    static func text(_ value: String, size: CGFloat, bold: Bool = false) -> Text {
        var result = Text("")
        var run = ""
        var ascii: Bool?
        func appendRun() {
            guard !run.isEmpty else { return }
            let face: Font = ascii == true ? font(size, bold: bold) : .system(size: size, weight: bold ? .semibold : .regular)
            result = result + Text(run).font(face)
        }
        for character in value {
            let isASCII = character.unicodeScalars.allSatisfy { $0.value < 128 }
            if let ascii, ascii != isASCII { appendRun(); run = "" }
            ascii = isASCII; run.append(character)
        }
        appendRun()
        return result
    }
}
