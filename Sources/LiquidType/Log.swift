import Foundation

/// 极简日志：stderr + ~/Library/Logs/LiquidType.log
enum Log {
    static let path: String = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("LiquidType.log").path
    }()

    private static let queue = DispatchQueue(label: "liquidtype.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ msg: String) {
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        queue.async {
            FileHandle.standardError.write(line.data(using: .utf8)!)
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                h.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
            }
        }
    }
}
