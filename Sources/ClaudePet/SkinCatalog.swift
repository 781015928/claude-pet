import AppKit
import Foundation
import Combine

/// 形象目录：合并 bundle 内置 (read-only) + 用户导入 (~/.claude-pet/pets/)。
/// 用户目录同 id 时**覆盖**内置（用户可以替换内置形象的素材）。
final class SkinCatalog: ObservableObject {
    @Published private(set) var skins: [PetSkin] = []

    private weak var settings: PetSettings?

    init() {
        refresh()
    }

    func attach(settings: PetSettings) {
        self.settings = settings
    }

    /// 扫描两个目录刷新可用 skin。
    func refresh() {
        var seen: [String: PetSkin] = [:]
        if let bundled = PetAssetLocator.bundledPetsDirectory {
            scan(bundled, isBuiltin: true, into: &seen)
        }
        scan(PetAssetLocator.userPetsDirectory, isBuiltin: false, into: &seen)
        skins = seen.values.sorted { $0.id < $1.id }
    }

    private func scan(_ dir: URL, isBuiltin: Bool, into result: inout [String: PetSkin]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for entry in entries {
            let id = entry.lastPathComponent
            if id.hasPrefix(".") { continue }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let spritePath = entry.appendingPathComponent("spritesheet.webp").path
            guard fm.fileExists(atPath: spritePath) else { continue }

            var displayName = id
            let petJson = entry.appendingPathComponent("pet.json")
            if let data = try? Data(contentsOf: petJson),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["displayName"] as? String, !name.isEmpty {
                displayName = name
            }
            // 用户目录覆盖 bundle 内置：保留 isBuiltin = false 让用户能删自己导入的副本
            result[id] = PetSkin(id: id, displayName: displayName, isBuiltin: isBuiltin)
        }
    }

    /// 把外部 webp 复制到 ~/.claude-pet/pets/<id>/，并写一份 pet.json。
    func importSprite(from sourceURL: URL, id rawID: String, displayName: String) throws -> PetSkin {
        let id = sanitize(id: rawID)
        try validate(id: id)
        if skins.contains(where: { $0.id == id }) {
            throw asError("已存在同名形象 \(id)")
        }

        let petsDir = PetAssetLocator.userPetsDirectory
        let fm = FileManager.default
        try fm.createDirectory(at: petsDir, withIntermediateDirectories: true)
        let targetDir = petsDir.appendingPathComponent(id)
        if fm.fileExists(atPath: targetDir.path) {
            throw asError("目录已存在：\(targetDir.path)")
        }
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: false)

        let target = targetDir.appendingPathComponent("spritesheet.webp")
        try fm.copyItem(at: sourceURL, to: target)

        let petJson: [String: Any] = [
            "id": id,
            "displayName": displayName.isEmpty ? id : displayName,
            "spritesheetPath": "spritesheet.webp"
        ]
        let jsonData = try JSONSerialization.data(
            withJSONObject: petJson,
            options: [.prettyPrinted, .sortedKeys]
        )
        try jsonData.write(to: targetDir.appendingPathComponent("pet.json"))

        let skin = PetSkin(
            id: id,
            displayName: displayName.isEmpty ? id : displayName,
            isBuiltin: false
        )
        refresh()
        return skin
    }

    /// 删除 skin —— 仅用户导入的可删，内置只读。
    func delete(_ skin: PetSkin) throws {
        guard !skin.isBuiltin else {
            throw asError("内置形象不可删除")
        }
        let dir = PetAssetLocator.userPetsDirectory.appendingPathComponent(skin.assetID)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        settings?.invalidateSheetCache(for: skin.assetID)
        refresh()
        if settings?.skin.id == skin.id {
            settings?.skin = skins.first ?? .placeholder
        }
    }

    // MARK: - 校验

    private func sanitize(id raw: String) -> String {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        return String(lower.compactMap { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    private func validate(id: String) throws {
        guard !id.isEmpty else { throw asError("id 不能为空") }
        guard id.count <= 40 else { throw asError("id 太长（最多 40 字符）") }
    }

    private func asError(_ message: String) -> NSError {
        NSError(domain: "SkinCatalog", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
