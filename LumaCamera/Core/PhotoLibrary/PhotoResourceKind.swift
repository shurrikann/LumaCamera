import Foundation
import UniformTypeIdentifiers

enum PhotoResourceKind {
    static func isRAW(typeIdentifier: String?, filename: String) -> Bool {
        if let typeIdentifier, let type = UTType(typeIdentifier) {
            if type.conforms(to: .rawImage) { return true }
            if type.conforms(to: .image) { return false }
        }
        return ["dng", "cr2", "cr3", "nef", "nrw", "arw", "raf", "rw2", "orf", "pef", "srw"].contains((filename as NSString).pathExtension.lowercased())
    }
}
