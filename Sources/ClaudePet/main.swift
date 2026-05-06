import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory: 无 Dock 图标，但保留菜单栏 / 浮窗
app.setActivationPolicy(.accessory)
app.run()
