import AppKit

/// 弹出面板时的音效。
///
/// 默认播放随包携带的 `duang.wav`（由 `tools/make-duang.py` 合成，见该脚本注释）；
/// 配置里也可以写任何系统音效名（`Hero`、`Glass`、`Pop`…），或留空关闭。
enum SoundPlayer {
    private static var cache: [String: NSSound] = [:]

    static func play(_ name: String) {
        let key = name.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }

        if let cached = cache[key] {
            cached.stop()
            cached.play()
            return
        }

        guard let sound = load(key) else {
            Log.write("音效 \(key) 找不到，已跳过")
            return
        }
        cache[key] = sound
        sound.play()
    }

    private static func load(_ name: String) -> NSSound? {
        for ext in ["wav", "aiff", "m4a", "caf"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let sound = NSSound(contentsOf: url, byReference: true) {
                return sound
            }
        }
        // 系统音效：/System/Library/Sounds/*.aiff
        return NSSound(named: NSSound.Name(name))
    }
}
