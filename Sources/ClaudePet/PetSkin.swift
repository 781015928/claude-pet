import AppKit
import Foundation
import Combine

/// 形象/皮肤。运行时通过 SkinCatalog 维护可用列表。
/// 所有 skin 都对应一份 sprite sheet（<pets>/<id>/spritesheet.webp）。
struct PetSkin: Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String
    /// app bundle 内置（read-only，不可删）；用户导入的为 false。
    var isBuiltin: Bool = false

    var assetID: String { id }

    /// 占位 skin —— catalog 为空时持有，PetView 会显示引导。
    static let placeholder = PetSkin(id: "__placeholder__", displayName: "(无可用形象)")

    /// 状态 → Codex 9 行动画映射（与 skin 无关，所有 sprite 共用）。
    func animation(for state: PetState) -> SpriteAnimation {
        switch state {
        case .idle:         return SpriteAnimation(.idle)
        case .thinking:     return SpriteAnimation(.review)
        case .working:      return SpriteAnimation(.running)
        case .notification: return SpriteAnimation(.waving)
        case .done:         return SpriteAnimation(.jumping)
        case .sleeping:     return SpriteAnimation(.waiting)
        case .running:      return SpriteAnimation(.runningLeft)
        case .failed:       return SpriteAnimation(.failed)
        }
    }
}

/// 鼠标追随模式。
enum FollowMode: String, CaseIterable {
    case off
    case afterTaskOnce
    case always

    var displayName: String {
        switch self {
        case .off:           return "不跟随鼠标"
        case .afterTaskOnce: return "任务完成后跟随"
        case .always:        return "永久跟随鼠标"
        }
    }
}

/// Codex 标准 9 行动画规范（行号 + 每帧时长）。
/// 数据来自 openai/skills 仓库 hatch-pet/references/animation-rows.md。
struct CodexRow {
    let row: Int
    let durations: [TimeInterval]

    static let idle = CodexRow(
        row: 0,
        durations: [0.280, 0.110, 0.110, 0.140, 0.140, 0.320]
    )
    static let runningRight = CodexRow(
        row: 1,
        durations: Array(repeating: 0.120, count: 7) + [0.220]
    )
    static let runningLeft = CodexRow(
        row: 2,
        durations: Array(repeating: 0.120, count: 7) + [0.220]
    )
    static let waving = CodexRow(
        row: 3,
        durations: [0.140, 0.140, 0.140, 0.280]
    )
    static let jumping = CodexRow(
        row: 4,
        durations: [0.140, 0.140, 0.140, 0.140, 0.280]
    )
    static let failed = CodexRow(
        row: 5,
        durations: Array(repeating: 0.140, count: 7) + [0.240]
    )
    static let waiting = CodexRow(
        row: 6,
        durations: [0.150, 0.150, 0.150, 0.150, 0.150, 0.260]
    )
    static let running = CodexRow(
        row: 7,
        durations: [0.120, 0.120, 0.120, 0.120, 0.120, 0.220]
    )
    static let review = CodexRow(
        row: 8,
        durations: [0.150, 0.150, 0.150, 0.150, 0.150, 0.280]
    )
}

/// 一段动画：行 + 每帧时长。
struct SpriteAnimation: Equatable {
    let row: Int
    let frameDurations: [TimeInterval]

    init(row: Int, frameDurations: [TimeInterval]) {
        self.row = row
        self.frameDurations = frameDurations
    }

    init(_ codexRow: CodexRow) {
        self.row = codexRow.row
        self.frameDurations = codexRow.durations
    }

    var frameCount: Int { frameDurations.count }
    var totalDuration: TimeInterval { frameDurations.reduce(0, +) }
}

/// 桌宠运行时设置。所有 @Published 字段都持久化到 UserDefaults。
final class PetSettings: ObservableObject {
    @Published var skin: PetSkin {
        didSet {
            if oldValue.id != skin.id {
                UserDefaults.standard.set(skin.id, forKey: Self.skinKey)
            }
        }
    }
    @Published var followMode: FollowMode {
        didSet {
            if oldValue != followMode {
                UserDefaults.standard.set(followMode.rawValue, forKey: Self.followKey)
            }
        }
    }
    /// 桌宠整体缩放，1.0 = 原大小；范围 0.5–2.0
    @Published var scale: Double {
        didSet {
            UserDefaults.standard.set(scale, forKey: Self.scaleKey)
        }
    }
    /// 气泡字体大小（pt），独立于整体 scale；范围 8–24
    @Published var bubbleFontSize: Double {
        didSet {
            UserDefaults.standard.set(bubbleFontSize, forKey: Self.bubbleFontKey)
        }
    }
    @Published var isFollowing: Bool = false
    @Published var connectedToClaude: Bool {
        didSet {
            UserDefaults.standard.set(connectedToClaude, forKey: Self.connectedKey)
        }
    }
    /// 是否允许 hook 触发时把桌宠 app 拉起来。
    @Published var hookAutoStart: Bool {
        didSet {
            UserDefaults.standard.set(hookAutoStart, forKey: Self.autoStartKey)
            Self.writeAutoStartMarker(enabled: hookAutoStart)
        }
    }
    var onCancelFollowRequest: (() -> Void)?

    private static let skinKey       = "ClaudePet.skin.id"
    private static let followKey     = "ClaudePet.followMode"
    private static let scaleKey      = "ClaudePet.scale"
    private static let bubbleFontKey = "ClaudePet.bubbleFontSize"
    private static let connectedKey  = "ClaudePet.connectedToClaude"
    private static let autoStartKey  = "ClaudePet.hookAutoStart"

    /// 上次保存的 skin id —— AppDelegate 启动时用来挑选初始 skin。
    static var lastSkinID: String? {
        UserDefaults.standard.string(forKey: skinKey)
    }

    private var sheetCache: [String: SpriteSheet] = [:]

    init(skin: PetSkin = .placeholder) {
        self.skin = skin

        let savedFollow = UserDefaults.standard.string(forKey: Self.followKey)
            .flatMap(FollowMode.init(rawValue:))
        self.followMode = savedFollow ?? .off

        let savedScale = UserDefaults.standard.double(forKey: Self.scaleKey)
        self.scale = (savedScale >= 0.5 && savedScale <= 2.0) ? savedScale : 1.0

        let savedFont = UserDefaults.standard.double(forKey: Self.bubbleFontKey)
        self.bubbleFontSize = (savedFont >= 8 && savedFont <= 24) ? savedFont : 11

        let actuallyInstalled = ClaudeHookInstaller.isInstalled()
        let lastKnown = UserDefaults.standard.bool(forKey: Self.connectedKey)
        self.connectedToClaude = actuallyInstalled || lastKnown

        let autoStart = UserDefaults.standard.bool(forKey: Self.autoStartKey)
        self.hookAutoStart = autoStart
        // marker 文件保持与 UserDefaults 一致
        Self.writeAutoStartMarker(enabled: autoStart)
    }

    /// hook 脚本通过 ~/.claude-pet/.autostart 文件判断是否在 app 未运行时启动 app。
    static func writeAutoStartMarker(enabled: Bool) {
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-pet")
            .appendingPathComponent(".autostart")
        let fm = FileManager.default
        try? fm.createDirectory(at: marker.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if enabled {
            fm.createFile(atPath: marker.path, contents: nil)
        } else if fm.fileExists(atPath: marker.path) {
            try? fm.removeItem(at: marker)
        }
    }

    func sheet(for skin: PetSkin) -> SpriteSheet? {
        let id = skin.assetID
        if let cached = sheetCache[id] { return cached }
        guard let url = PetAssetLocator.spritesheetURL(for: id) else { return nil }
        if let sheet = SpriteSheet(url: url) {
            sheetCache[id] = sheet
            return sheet
        }
        return nil
    }

    /// 删除 skin 对应缓存（由 SkinCatalog 在 delete 后调用，避免拿旧图）。
    func invalidateSheetCache(for assetID: String) {
        sheetCache.removeValue(forKey: assetID)
    }
}

/// 资源定位 —— 分内置（bundle 只读）和用户（home 可写）两份。
enum PetAssetLocator {
    /// 用户导入的 sprite 写入位置（持久化）。
    static var userPetsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-pet")
            .appendingPathComponent("pets")
    }

    /// 内置 sprite 目录：
    /// - Release（.app）：bundle Resources/pets/
    /// - Dev（swift run）：项目根 pets/
    /// - 也可以通过 PETS_DIR 环境变量强制覆盖
    static var bundledPetsDirectory: URL? {
        if let env = ProcessInfo.processInfo.environment["PETS_DIR"], !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        // 1) Bundle resources（打包后）
        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appendingPathComponent("pets")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // 2) 项目根（dev: .build/<arch>/<config>/<exe> → 上 4 级）
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: "/")
        let projectRoot = exe
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = projectRoot.appendingPathComponent("pets")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// 用户优先 → bundle 兜底。
    static func spritesheetURL(for assetID: String) -> URL? {
        let user = userPetsDirectory.appendingPathComponent(assetID)
            .appendingPathComponent("spritesheet.webp")
        if FileManager.default.fileExists(atPath: user.path) {
            return user
        }
        if let bundled = bundledPetsDirectory {
            let p = bundled.appendingPathComponent(assetID)
                .appendingPathComponent("spritesheet.webp")
            if FileManager.default.fileExists(atPath: p.path) {
                return p
            }
        }
        return nil
    }
}
