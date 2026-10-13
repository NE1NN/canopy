import CanopyAgents
import Foundation

extension BoxDaemon {
    /// Learns which instance the box is, once a wake key needs it, from the instance metadata service, or the
    /// loopback stand-in a test names in `box/imds`. Does nothing once known, or while another call asks.
    public func learnInstance() async {
        guard !learningInstance, wakeKey != nil, !FileManager.default.fileExists(atPath: paths.instanceFile) else {
            return
        }
        learningInstance = true
        defer { learningInstance = false }
        let (address, port) = BoxMain.loopbackOverride(paths.folder + "/imds")
        guard
            let identity = await InstanceMetadata.identity(
                address: address ?? InstanceMetadata.address, port: port ?? InstanceMetadata.port)
        else { return }
        try? BoxFiles.write(try JSONEncoder.box.encode(identity), to: paths.instanceFile)
    }
}
