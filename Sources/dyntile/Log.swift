import Foundation

enum Log {
    nonisolated(unsafe) static var verbose = false
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func debug(_ msg: @autoclosure () -> String) {
        guard verbose else { return }
        FileHandle.standardError.write("[\(fmt.string(from: Date()))] \(msg())\n".data(using: .utf8)!)
    }

    static func info(_ msg: String) {
        FileHandle.standardError.write("[\(fmt.string(from: Date()))] \(msg)\n".data(using: .utf8)!)
    }

    static func error(_ msg: String) {
        FileHandle.standardError.write("[\(fmt.string(from: Date()))] error: \(msg)\n".data(using: .utf8)!)
    }
}
