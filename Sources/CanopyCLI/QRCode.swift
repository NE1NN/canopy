import CoreImage
import Foundation

/// QR codes for the terminal, so `canopy phone pair` can show one.
enum QRCode {
    /// The code's modules, true for dark, row by row, without a quiet zone.
    static func matrix(for text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        CIContext(options: [.useSoftwareRenderer: true]).render(
            image, toBitmap: &pixels, rowBytes: width, bounds: image.extent, format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray())
        let rows = (0..<height).map { y in (0..<width).map { x in pixels[y * width + x] < 128 } }
        return trimmed(rows)
    }

    /// Two rows of modules per line in half blocks, with dark modules drawn. `colored` draws black on white, so the
    /// code reads the right way round whatever the terminal's colors.
    static func text(_ matrix: [[Bool]], quietZone: Int = 4, colored: Bool) -> String {
        let width = (matrix.first?.count ?? 0) + 2 * quietZone
        let blank = [Bool](repeating: false, count: width)
        let margin = [Bool](repeating: false, count: quietZone)
        var rows =
            Array(repeating: blank, count: quietZone) + matrix.map { margin + $0 + margin }
            + Array(repeating: blank, count: quietZone)
        if rows.count % 2 == 1 { rows.append(blank) }
        return stride(from: 0, to: rows.count, by: 2).map { index in
            let line = String(
                zip(rows[index], rows[index + 1]).map { top, bottom -> Character in
                    switch (top, bottom) {
                    case (true, true): "█"
                    case (true, false): "▀"
                    case (false, true): "▄"
                    case (false, false): " "
                    }
                })
            return colored ? "\u{1b}[30;107m" + line + "\u{1b}[0m" : line
        }.joined(separator: "\n")
    }

    /// Core Image adds a quiet zone of its own, which `text` draws to the size it wants.
    private static func trimmed(_ rows: [[Bool]]) -> [[Bool]] {
        let dark = rows.indices.filter { rows[$0].contains(true) }
        let columns = (rows.first ?? []).indices.filter { column in rows.contains { $0[column] } }
        guard let top = dark.first, let bottom = dark.last, let left = columns.first, let right = columns.last else {
            return rows
        }
        return rows[top...bottom].map { Array($0[left...right]) }
    }
}
