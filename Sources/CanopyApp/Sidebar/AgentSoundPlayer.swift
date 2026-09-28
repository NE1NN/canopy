import AppKit

/// Plays the sounds for agents finishing and waiting. A sound already playing is not started again, so several
/// agents finishing together play it once.
@MainActor
final class AgentSoundPlayer {
    private var sounds: [String: NSSound] = [:]

    /// `sound` is a system sound's name, such as Glass, or a sound file's path. One that cannot be found plays
    /// `fallback` instead.
    func play(_ sound: String, fallback: String) {
        guard let player = load(sound) ?? load(fallback), !player.isPlaying else { return }
        player.play()
    }

    private func load(_ sound: String) -> NSSound? {
        if let cached = sounds[sound] { return cached }
        let player =
            sound.contains("/")
            ? NSSound(contentsOfFile: (sound as NSString).expandingTildeInPath, byReference: true)
            : NSSound(named: NSSound.Name(sound))
        sounds[sound] = player
        return player
    }
}
