import ArgumentParser
import CanopyCore

@main
struct CanopyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "canopy",
        abstract: "Drive Canopy from the command line.",
        version: CanopyVersion.current
    )
}
