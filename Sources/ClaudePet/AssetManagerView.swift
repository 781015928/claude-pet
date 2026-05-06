import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 素材管理面板：列出可用形象、导入新 webp、删除。
struct AssetManagerView: View {
    @ObservedObject var catalog: SkinCatalog
    @ObservedObject var settings: PetSettings
    var onClose: () -> Void

    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("素材管理")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            if let err = errorText {
                Text(err)
                    .font(.callout)
                    .foregroundColor(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(6)
            }

            List {
                ForEach(catalog.skins) { skin in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skin.displayName).fontWeight(.medium)
                            HStack(spacing: 6) {
                                Text(skin.id)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                                if skin.isBuiltin {
                                    Tag(text: "内置", color: .blue)
                                } else {
                                    Tag(text: "自定义", color: .green)
                                }
                                if skin.id == settings.skin.id {
                                    Tag(text: "当前", color: .orange)
                                }
                            }
                        }
                        Spacer()
                        if skin.isBuiltin {
                            Text("内置只读")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Button {
                                delete(skin)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 280)

            HStack {
                Button {
                    importSprite()
                } label: {
                    Label("导入 sprite sheet…", systemImage: "square.and.arrow.down")
                }
                Spacer()
                Button("关闭") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("提示：素材应为 1536×1872 的 webp，按 Codex 9 行 ×8 列 (192×208 / 帧) 排布。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(width: 460, height: 480)
    }

    // MARK: - 操作

    private func delete(_ skin: PetSkin) {
        let alert = NSAlert()
        alert.messageText = "删除 \(skin.displayName)？"
        alert.informativeText = "将删除 pets/\(skin.id)/ 目录及其中的 spritesheet。此操作不可恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try catalog.delete(skin)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importSprite() {
        let panel = NSOpenPanel()
        panel.title = "选择 sprite sheet (webp)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *), let webp = UTType(filenameExtension: "webp") {
            panel.allowedContentTypes = [webp]
        } else {
            panel.allowedFileTypes = ["webp"]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 让用户填 id + displayName
        let inputAlert = NSAlert()
        inputAlert.messageText = "命名新形象"
        inputAlert.informativeText = "id 用于目录名，仅小写字母 / 数字 / - / _。"
        inputAlert.addButton(withTitle: "导入")
        inputAlert.addButton(withTitle: "取消")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 60)
        let idField = NSTextField(string: defaultID(from: url))
        idField.placeholderString = "id（如 my-pug）"
        idField.frame = NSRect(x: 0, y: 30, width: 280, height: 24)
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "显示名（可留空 = id）"
        nameField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        stack.addArrangedSubview(idField)
        stack.addArrangedSubview(nameField)
        inputAlert.accessoryView = stack
        let resp = inputAlert.runModal()
        guard resp == .alertFirstButtonReturn else { return }

        do {
            _ = try catalog.importSprite(
                from: url,
                id: idField.stringValue,
                displayName: nameField.stringValue
            )
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func defaultID(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

private struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }
}

/// 包装窗口：宿主在 NSHostingController，关闭时回调释放。
final class AssetManagerWindow: NSWindow {
    init(catalog: SkinCatalog, settings: PetSettings, onClose: @escaping () -> Void) {
        let view = AssetManagerView(catalog: catalog, settings: settings, onClose: {
            // 关闭由 SwiftUI 触发 → 让 window 也走 close 流程
            NSApp.keyWindow?.close()
            onClose()
        })
        let host = NSHostingController(rootView: view)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        self.title = "桌宠素材"
        self.contentViewController = host
        self.center()
        self.isReleasedWhenClosed = false
    }
}
