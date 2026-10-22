import AppKit

/// Standard application menu items belong to AppKit, outside the SwiftUI view
/// tree. Translate known roles only; never rewrite user preset/snapshot names.
@MainActor enum LocalizedApplicationMenus {
    static func refresh() {
        guard let main = NSApp?.mainMenu else { return }
        let english = L10n.isEnglish
        let headings = [("文件","File"),("编辑","Edit"),("显示","View"),("窗口","Window"),("帮助","Help")]
        for item in main.items {
            if let pair = headings.first(where: { item.title == $0.0 || item.title == $0.1 }) {
                item.title = english ? pair.1 : pair.0; item.submenu?.title = item.title
            }
        }
        let roles:[String:(String,String)] = [
            "performClose:":("关闭窗口","Close Window"), "terminate:":("退出 Phos","Quit Phos"),
            "hide:":("隐藏 Phos","Hide Phos"), "hideOtherApplications:":("隐藏其他","Hide Others"),
            "unhideAllApplications:":("显示全部","Show All"), "orderFrontStandardAboutPanel:":("关于 Phos","About Phos"),
            "cut:":("剪切","Cut"), "copy:":("拷贝","Copy"), "paste:":("粘贴","Paste"),
            "pasteAsPlainText:":("粘贴并匹配样式","Paste and Match Style"), "selectAll:":("全选","Select All"),
            "delete:":("删除","Delete"), "performMiniaturize:":("最小化","Minimize"),
            "performZoom:":("缩放","Zoom"), "arrangeInFront:":("前置全部窗口","Bring All to Front"),
            "toggleFullScreen:":("切换全屏幕","Toggle Full Screen"),
            "orderFrontCharacterPalette:":("表情与符号","Emoji & Symbols"),
            "startSpeaking:":("开始朗读","Start Speaking"), "stopSpeaking:":("停止朗读","Stop Speaking")
        ]
        func visit(_ menu:NSMenu) {
            for item in menu.items {
                if let action = item.action, let pair = roles[NSStringFromSelector(action)] { item.title = english ? pair.1 : pair.0 }
                if let submenu = item.submenu { visit(submenu) }
            }
        }
        visit(main)
    }
}
