# dmgbuild 配置：DMG 安装窗口的布局。
#
# 不用 Finder AppleScript —— 那需要图形会话与「自动化」权限，在 CI 和无头环境下不可靠。
# dmgbuild 直接生成 .DS_Store，本地和 CI 都能跑出同样的结果。
#
# 由 Scripts/make_dmg.sh 调用，靠两个环境变量定位素材：
#   DMG_STAGE  待打包目录（里面有 Phos.app 和「首次打开必读.txt」）
#   DMG_ASSETS 背景图所在目录

import os

stage = os.environ.get("DMG_STAGE", ".")
assets = os.environ.get("DMG_ASSETS", ".")

files = [os.path.join(stage, "Phos.app")]
readme = os.path.join(stage, "首次打开必读.txt")
if os.path.exists(readme):
    files.append(readme)

# 「拖到应用程序」的那个快捷方式
symlinks = {"Applications": "/Applications"}

# 背景图：由 make_dmg.sh 用 tiffutil 合成的**多分辨率 TIFF**
# （内含 660×420@72dpi 与 1320×840@144dpi 两档，Finder 在 Retina 上自动挑后者）。
# 直接给 PNG 的话 dmgbuild 会转成单分辨率 TIFF，Retina 上会发虚。
background = os.environ.get("DMG_BACKGROUND", os.path.join(assets, "background.tiff"))

# 窗口：内容区 660×460，与背景图一致（Tools/DMGBackground.swift 里的 height）
window_rect = ((260, 180), (660, 460))
default_view = "icon-view"

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 96
text_size = 12

# ⚠️ 图标位置的 y 是「从窗口顶部往下」算的，和背景图（CoreGraphics，从底部往上）相反。
# 之前按从底部算，把「首次打开必读.txt」放到了 (330, 96) —— 结果它跑到标题上去了。
#
# 版面自上而下：标题 / 副标题 / 拖拽提示（背景图上画好）→ 两个图标 → 必读文件。
# 背景图里的箭头画在 arrowY = 255（从底部算），换算成从顶部算是 460-255 = 205，
# 所以两个图标的 y 用 205，正好压在箭头两端。
icon_locations = {
    "Phos.app": (165, 205),
    "Applications": (495, 205),
    "首次打开必读.txt": (330, 345),
}
