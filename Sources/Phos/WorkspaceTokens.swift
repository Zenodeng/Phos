import AppKit
import SwiftUI

/// Shared visual vocabulary. The S1 lab uses these first; production migration is staged.
enum WorkspaceTokens {
    enum Space { static let xs: CGFloat = 4; static let sm: CGFloat = 8; static let md: CGFloat = 12; static let lg: CGFloat = 16; static let xl: CGFloat = 24 }
    enum TypeSize { static let metadata: CGFloat = 11; static let parameter: CGFloat = 12; static let group: CGFloat = 13; static let panel: CGFloat = 15; static let dialog: CGFloat = 20 }
    static let symbolBox: CGFloat = 24
    static let readout = CGSize(width:64,height:24)
    static let panelRadius: CGFloat = 18
    static let controlRadius: CGFloat = 6
    /// 品牌金 #C9A876（见 Theme.swift 的 NSColor.rfGold）。唯一强调色。
    /// 按官网「石墨 × 香槟金」：金色不装饰，只表达状态——选中环、滑杆填充、
    /// 胶片卡、导出主按钮。看到金色，就是在编辑。
    static let gold = Color(nsColor: .rfGold)
    static let accent = gold
    static let primaryText = Color(nsColor: .rfDynamic(light:NSColor(white:0.10,alpha:1),dark:NSColor(white:0.96,alpha:1)))
    static let secondaryText = Color(nsColor: .rfDynamic(light:NSColor(white:0.23,alpha:1),dark:NSColor(white:0.79,alpha:1)))
    static let error = Color(nsColor: .rfDynamic(light:NSColor(red:0.72,green:0.09,blue:0.13,alpha:1),dark:NSColor(red:1,green:0.60,blue:0.62,alpha:1)))
    static let success = Color(nsColor: .rfDynamic(light:NSColor(red:0.12,green:0.43,blue:0.26,alpha:1),dark:NSColor(red:0.45,green:0.83,blue:0.58,alpha:1)))
    static let panel = NSColor.rfDynamic(light:NSColor(white:0.96,alpha:1),dark:NSColor(white:0.13,alpha:1))
    static let readoutColor = Color(nsColor:.rfDynamic(light:NSColor(white:0.98,alpha:1),dark:NSColor(white:0.19,alpha:1)))
    static let readoutTop = Color(nsColor:.rfDynamic(light:NSColor(white:1,alpha:1),dark:NSColor(white:0.21,alpha:1)))
    static let readoutBottom = Color(nsColor:.rfDynamic(light:NSColor(white:0.96,alpha:1),dark:NSColor(white:0.18,alpha:1)))
    static let chartColor = Color(nsColor:.rfDynamic(light:NSColor(white:0.98,alpha:0.94),dark:NSColor(white:0.10,alpha:0.96)))
    static let hairline = Color.primary.opacity(0.10)
}

/// Same finite-number, comma, rounding and clamping rules as the existing SliderRow.
enum ParameterInputPolicy {
    static func value(_ draft: String, in range: ClosedRange<Double>) -> Double? {
        var raw = draft.trimmingCharacters(in:.whitespaces)
        if raw.contains("."), !raw.contains(",") { } else if raw.contains(",") { raw = raw.replacingOccurrences(of:",",with:".") }
        guard let value = Double(raw), value.isFinite else { return nil }
        let rounded = (value*100).rounded()/100
        return min(max(rounded,range.lowerBound),range.upperBound)
    }
}
