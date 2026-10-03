# 线性渐变蒙版不显示参考线的问题修复

## 问题描述
当选择线性渐变蒙版时，只能看到两个控制点（青色圆点），但是看不到三条白色虚线参考线。

## 根本原因
在 `Views.swift` 的第 443 行，`MaskOverlay` 的显示条件是：
```swift
if !s.cropMode, !s.showBefore, !s.whiteBalancePicker, s.maskTool == .position,
   let m = s.maskDraft ?? s.selectedMask.flatMap({ id in s.params.masks.first(where: { $0.id == id }) })
```

这意味着只有当 `s.maskTool == .position` 时，蒙版的可视化控制点和参考线才会显示。

但是在原代码中，当用户点击蒙版列表选择一个蒙版时，只设置了 `selectedMask`，**没有同时设置 `maskTool = .position`**，导致蒙版被选中但可视化层不显示。

## 修复内容

### 1. Inspector.swift (第 806 行)
**修改前：**
```swift
.onTapGesture { s.selectedMask = (isSel ? nil : m.id) }
```

**修改后：**
```swift
.onTapGesture {
    if isSel {
        s.selectedMask = nil
    } else {
        s.selectedMask = m.id
        s.maskTool = .position  // 添加这行
    }
}
```

### 2. AppMain.swift - addMask 方法 (第 526 行)
**修改前：**
```swift
func addMask(_ kind: MaskKind) {
    var m = Mask()
    m.kind = kind
    m.name = kind.label
    var p = params
    p.masks.append(m)
    selectedMask = m.id
    commit(p)
}
```

**修改后：**
```swift
func addMask(_ kind: MaskKind) {
    var m = Mask()
    m.kind = kind
    m.name = kind.label
    var p = params
    p.masks.append(m)
    selectedMask = m.id
    maskTool = .position  // 添加这行
    commit(p)
}
```

### 3. AppMain.swift - duplicateMask 方法 (第 515 行)
**修改前：**
```swift
selectedMask = copy.id
```

**修改后：**
```swift
selectedMask = copy.id
maskTool = .position  // 添加这行
```

### 4. AppMain.swift - finishMaskDrawing 方法 (第 501 行)
**修改前：**
```swift
selectedMask = draft.id
status = "已绘制\(draft.kind.label)；拖中心移动，拖边界缩放，拖旋转柄改变方向"
```

**修改后：**
```swift
selectedMask = draft.id
maskTool = .position  // 添加这行
status = "已绘制\(draft.kind.label)；拖中心移动，拖边界缩放，拖旋转柄改变方向"
```

## 预期效果
修复后，当用户：
1. 点击蒙版列表选择一个线性/径向渐变蒙版
2. 创建新的蒙版
3. 复制蒙版
4. 完成渐变绘制

都会自动将 `maskTool` 设置为 `.position`，从而显示完整的可视化控制界面：
- **线性渐变**：三条白色虚线（起点/中心/终点）+ 青色控制点 + 白色中心点 + 橙色旋转柄
- **径向渐变**：黄色椭圆外圈 + 黄色虚线内圈（羽化边界）+ 黄色控制点 + 橙色旋转柄

## 测试建议
1. 重新编译项目
2. 打开 Phos.app
3. 导入一张图片
4. 在右侧面板点击"线性渐变"按钮
5. 在画布上拖拽创建渐变
6. 松手后应该能看到完整的参考线和控制点
7. 在蒙版列表中点击其他蒙版再点回来，参考线应该保持显示
