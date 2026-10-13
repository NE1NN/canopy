/// Where canopy-box keeps a Canopy home's files on a host.
public struct BoxPaths: Sendable, Equatable {
    /// The folder holding `.canopy`, normally the user's home.
    public var root: String
    public var homeID: String

    public init(root: String, homeID: String) {
        self.root = root
        self.homeID = homeID
    }
}
