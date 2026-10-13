import CanopyAgents
import Foundation

extension BoxDaemon {
    /// Learns which instance the box is, once a wake key needs it, from the instance metadata service, or the
    /// loopback stand-in a test names in `box/imds`. Does nothing once known, unless `again`, as at start, since the box's
    /// files may have moved to another instance; then a service that does not answer leaves what was known. A call
    /// while another asks waits for it, then asks itself if it still needs to.
    public func learnInstance(again: Bool = false) async {
        // Waits out a lookup under way, then asks itself when it still needs to, as a call `again` does.
        while let learning = instanceLearning {
            await learning.value
            if instanceLearning == learning { instanceLearning = nil }
        }
        guard wakeKey != nil, again || !FileManager.default.fileExists(atPath: paths.instanceFile) else { return }
        let paths = paths
        let learning = Task {
            let (address, port) = BoxMain.loopbackOverride(paths.folder + "/imds")
            guard
                let identity = await InstanceMetadata.identity(
                    address: address ?? InstanceMetadata.address, port: port ?? InstanceMetadata.port)
            else { return }
            try? BoxFiles.write(try JSONEncoder.box.encode(identity), to: paths.instanceFile)
        }
        instanceLearning = learning
        await learning.value
        if instanceLearning == learning { instanceLearning = nil }
    }
}
