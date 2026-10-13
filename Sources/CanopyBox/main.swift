import CanopyBoxKit
import CanopyWire
import Foundation

let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "version" {
    print(CanopyVersion.current)
} else {
    print("usage: canopy-box version")
    exit(2)
}
