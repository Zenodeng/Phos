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

# 窗口：内容区 660×420，与背景图一致
window_rect = ((260, 200), (660, 420))
default_view = "icon-view"

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 96
text_size = 12

# 图标位置用「窗口左下角为原点」的坐标，与背景图上画的位置对应
icon_locations = {
    "Phos.app": (165, 205),
    "Applications": (495, 205),
    "首次打开必读.txt": (330, 96),
}
