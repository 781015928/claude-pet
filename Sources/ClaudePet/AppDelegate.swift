import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var petWindow: PetWindow!
    private var hookServer: HookServer!
    private var mouseTracker: MouseTracker!
    private let stateMachine = PetStateMachine()
    private let catalog = SkinCatalog()
    private lazy var settings: PetSettings = {
        // 优先 1) 上次保存的 skin id 2) rio 3) catalog 第一个 4) placeholder
        let initial = catalog.skins.first(where: { $0.id == PetSettings.lastSkinID })
            ?? catalog.skins.first(where: { $0.id == "rio" })
            ?? catalog.skins.first
            ?? .placeholder
        let s = PetSettings(skin: initial)
        catalog.attach(settings: s)
        return s
    }()
    private var statusItem: NSStatusItem!
    private var skinSubmenu: NSMenu!
    private var followSubmenu: NSMenu!
    private var connectMenuItem: NSMenuItem!
    private var assetManagerWindow: AssetManagerWindow?
    private var cancellables = Set<AnyCancellable>()
    private var autoStartMenuItem: NSMenuItem!
    private var scaleSliderLabel: NSTextField!
    private var bubbleFontSliderLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = settings  // 触发 lazy 初始化（含 catalog.attach）
        setupStatusBar()
        setupWindowAndTracker()
        setupHookServer()

        // 已连接的用户启动时自动重写一次脚本 + settings.json：
        // 升级版本时（比如 hook 脚本路径变更）保证 settings 指向最新位置
        if settings.connectedToClaude {
            do {
                try ClaudeHookInstaller.install()
            } catch {
                NSLog("[ClaudePet] auto-reinstall failed: \(error)")
            }
        }

        // catalog 变化（导入 / 删除）→ 刷新 skin 子菜单
        catalog.$skins
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildSkinSubmenu() }
            .store(in: &cancellables)

        // 当前 skin 切换（删除当前 skin 时被切回 .bazahei）→ 刷新菜单勾选
        settings.$skin
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildSkinSubmenu() }
            .store(in: &cancellables)
    }

    // MARK: - 菜单栏

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐶"
        statusItem.button?.toolTip = "巴扎黑 — Claude Code 桌宠"

        let menu = NSMenu()
        menu.addItem(withTitle: "显示宠物", action: #selector(showPet), keyEquivalent: "p").target = self
        menu.addItem(withTitle: "隐藏宠物", action: #selector(hidePet), keyEquivalent: "h").target = self
        menu.addItem(.separator())

        // 形象切换子菜单
        skinSubmenu = NSMenu(title: "形象")
        rebuildSkinSubmenu()
        let skinItem = NSMenuItem(title: "形象", action: nil, keyEquivalent: "")
        skinItem.submenu = skinSubmenu
        menu.addItem(skinItem)

        // 素材管理（导入 / 删除）
        let manageItem = NSMenuItem(title: "素材管理…",
                                    action: #selector(openAssetManager),
                                    keyEquivalent: ",")
        manageItem.target = self
        menu.addItem(manageItem)

        // 追随鼠标子菜单
        followSubmenu = NSMenu(title: "鼠标追随")
        rebuildFollowSubmenu()
        let followItem = NSMenuItem(title: "鼠标追随", action: nil, keyEquivalent: "")
        followItem.submenu = followSubmenu
        menu.addItem(followItem)

        menu.addItem(.separator())

        // 连接到 Claude Code（toggle）
        connectMenuItem = NSMenuItem(title: "连接到 Claude Code",
                                     action: #selector(toggleClaudeConnection),
                                     keyEquivalent: "")
        connectMenuItem.target = self
        connectMenuItem.state = settings.connectedToClaude ? .on : .off
        connectMenuItem.toolTip = "把桌宠 hook 注入 ~/.claude/settings.json，再次点击撤销"
        menu.addItem(connectMenuItem)

        // hook 触发时自动启动桌宠（toggle）
        autoStartMenuItem = NSMenuItem(title: "Hook 触发时自动启动",
                                       action: #selector(toggleAutoStart),
                                       keyEquivalent: "")
        autoStartMenuItem.target = self
        autoStartMenuItem.state = settings.hookAutoStart ? .on : .off
        autoStartMenuItem.toolTip = "桌宠未运行时，Claude hook 触发会自动把 app 拉起来"
        menu.addItem(autoStartMenuItem)

        menu.addItem(.separator())

        // 缩放滑块（NSSlider 嵌入 NSMenuItem.view）
        menu.addItem(makeScaleSliderItem())
        // 气泡字体大小滑块（独立于整体 scale）
        menu.addItem(makeBubbleFontSliderItem())

        menu.addItem(.separator())
        menu.addItem(withTitle: "跑一下！", action: #selector(runPet), keyEquivalent: "g").target = self
        menu.addItem(withTitle: "重置位置", action: #selector(resetPosition), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    private func rebuildSkinSubmenu() {
        skinSubmenu.removeAllItems()
        for skin in catalog.skins {
            let item = NSMenuItem(title: skin.displayName,
                                  action: #selector(switchSkin(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = skin.id
            item.state = (skin.id == settings.skin.id) ? .on : .off
            skinSubmenu.addItem(item)
        }
    }

    @objc private func switchSkin(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? String,
            let skin = catalog.skins.first(where: { $0.id == id })
        else { return }
        settings.skin = skin
        rebuildSkinSubmenu()
    }

    @objc private func openAssetManager() {
        if assetManagerWindow == nil {
            assetManagerWindow = AssetManagerWindow(
                catalog: catalog,
                settings: settings,
                onClose: { [weak self] in
                    self?.assetManagerWindow = nil
                }
            )
        }
        // 让窗口可被点击 / 抢焦点
        NSApp.activate(ignoringOtherApps: true)
        assetManagerWindow?.makeKeyAndOrderFront(nil)
    }

    private func rebuildFollowSubmenu() {
        followSubmenu.removeAllItems()
        for mode in FollowMode.allCases {
            let item = NSMenuItem(title: mode.displayName,
                                  action: #selector(switchFollowMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == settings.followMode) ? .on : .off
            followSubmenu.addItem(item)
        }
    }

    @objc private func switchFollowMode(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let mode = FollowMode(rawValue: raw)
        else { return }
        settings.followMode = mode
        rebuildFollowSubmenu()
    }

    @objc private func toggleClaudeConnection() {
        if settings.connectedToClaude {
            // 撤销
            do {
                try ClaudeHookInstaller.uninstall()
                settings.connectedToClaude = false
                showInfo(title: "已断开 Claude 连接", text: "桌宠 hook 已从 ~/.claude/settings.json 移除。")
            } catch {
                showError(title: "撤销失败", error: error)
            }
        } else {
            // 安装
            do {
                try ClaudeHookInstaller.install()
                settings.connectedToClaude = true
                showInfo(
                    title: "已连接到 Claude Code",
                    text: "hook 已注入。在新打开的 Claude Code 会话里桌宠会自动响应事件。"
                )
            } catch {
                showError(title: "连接失败", error: error)
            }
        }
        connectMenuItem.state = settings.connectedToClaude ? .on : .off
    }

    @objc private func toggleAutoStart() {
        settings.hookAutoStart.toggle()
        autoStartMenuItem.state = settings.hookAutoStart ? .on : .off
    }

    private func makeScaleSliderItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 44))

        let label = NSTextField(labelWithString: scaleLabelText())
        label.frame = NSRect(x: 14, y: 22, width: 192, height: 16)
        label.font = NSFont.menuFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)
        scaleSliderLabel = label

        let slider = NSSlider(value: settings.scale,
                              minValue: 0.5,
                              maxValue: 2.0,
                              target: self,
                              action: #selector(scaleSliderChanged(_:)))
        slider.frame = NSRect(x: 14, y: 4, width: 192, height: 20)
        slider.numberOfTickMarks = 7
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        view.addSubview(slider)

        item.view = view
        return item
    }

    @objc private func scaleSliderChanged(_ sender: NSSlider) {
        // 量化到 0.05，避免浮点抖动
        let v = (sender.doubleValue * 20).rounded() / 20
        settings.scale = v
        scaleSliderLabel.stringValue = scaleLabelText()
    }

    private func scaleLabelText() -> String {
        "缩放：\(Int((settings.scale * 100).rounded()))%"
    }

    private func makeBubbleFontSliderItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 44))

        let label = NSTextField(labelWithString: bubbleFontLabelText())
        label.frame = NSRect(x: 14, y: 22, width: 192, height: 16)
        label.font = NSFont.menuFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)
        bubbleFontSliderLabel = label

        let slider = NSSlider(value: settings.bubbleFontSize,
                              minValue: 8,
                              maxValue: 24,
                              target: self,
                              action: #selector(bubbleFontSliderChanged(_:)))
        slider.frame = NSRect(x: 14, y: 4, width: 192, height: 20)
        slider.numberOfTickMarks = 9   // 8 / 10 / 12 / 14 / 16 / 18 / 20 / 22 / 24
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        view.addSubview(slider)

        item.view = view
        return item
    }

    @objc private func bubbleFontSliderChanged(_ sender: NSSlider) {
        // 1pt 精度
        let v = sender.doubleValue.rounded()
        settings.bubbleFontSize = v
        bubbleFontSliderLabel.stringValue = bubbleFontLabelText()
    }

    private func bubbleFontLabelText() -> String {
        "气泡字体：\(Int(settings.bubbleFontSize.rounded()))pt"
    }

    private func showInfo(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func showError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func showPet() { petWindow.orderFrontRegardless() }
    @objc private func hidePet() { petWindow.orderOut(nil) }
    @objc private func resetPosition() { petWindow.moveToBottomRight() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func runPet() {
        // PetWindow 监听 state==.running 自动跑窗口
        stateMachine.startRunning(duration: 6)
    }

    // MARK: - 窗口 + 鼠标追踪

    private func setupWindowAndTracker() {
        // mouseTracker 需要在 window 之前创建（持有 weak window 引用）
        var weakWindowRef: () -> NSRect? = { nil }
        mouseTracker = MouseTracker(windowFrameProvider: { weakWindowRef() })

        petWindow = PetWindow(stateMachine: stateMachine, mouseTracker: mouseTracker, settings: settings)
        petWindow.moveToBottomRight()
        petWindow.orderFrontRegardless()

        weakWindowRef = { [weak petWindow] in petWindow?.frame }
        // 用户要求 1–2s 之间，取 1.5s 折中
        mouseTracker.start(interval: 1.5)
    }

    // MARK: - Hook server

    private func setupHookServer() {
        hookServer = HookServer(port: 54321) { [weak self] event in
            self?.stateMachine.handle(event: event)
        }
        do {
            try hookServer.start()
            NSLog("[ClaudePet] hook server listening on 127.0.0.1:54321")
        } catch {
            NSLog("[ClaudePet] hook server failed to start: \(error)")
        }
    }
}
