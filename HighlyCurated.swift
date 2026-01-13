// HighlyCurated.swift
// High-performance file organization utility for macOS
// Author: github.com/narlyseorg
// Compile: swiftc -O -whole-module-optimization -parse-as-library HighlyCurated.swift -o highlycurated
// Usage: ./highlycurated [--verbose]

import Foundation
import Darwin
import Dispatch
import os.log

// MARK: - Configuration

struct Config {
    static var downloadsDir: URL {
        if let env = ProcessInfo.processInfo.environment["HIGHLYCURATED_DOWNLOADS_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
    static var logFile: URL {
        if let env = ProcessInfo.processInfo.environment["HIGHLYCURATED_LOG_FILE"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: false)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/highlycurated.log")
    }
    static var lockFile: URL {
        if let env = ProcessInfo.processInfo.environment["HIGHLYCURATED_LOCK_FILE"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: false)
        }
        return URL(fileURLWithPath: "/tmp/highlycurated.lock")
    }
    static let maxLogSize: UInt64 = 1_048_576
    static var maxMoveRetries: Int {
        if let env = ProcessInfo.processInfo.environment["HIGHLYCURATED_MAX_RETRIES"],
           let val = Int(env), val > 0 { return val }
        return 100
    }
    static var logRetentionCount: Int {
        if let env = ProcessInfo.processInfo.environment["HIGHLYCURATED_LOG_RETENTION"],
           let val = Int(env), val >= 0 { return val }
        return 5  // Keep last 5 rotated logs
    }
}

// MARK: - Category System

enum FileCategory: String, CaseIterable {
    case documents = "Documents"
    case scripts = "Scripts"
    case images = "Images"
    case compressed = "Compressed"
    case programs = "Programs"
    case certificates = "Certificates"
    case videos = "Videos"
    case music = "Music"
    case disks = "Disks"
    case fonts = "Fonts"
    case torrents = "Torrents"
    case others = "Others"
    
    private static let extensionMap: [String: FileCategory] = {
        var map = [String: FileCategory]()
        for ext in ["doc","docx","odt","pdf","xls","xlsx","ods","csv","ppt","pptx","odp","pages","numbers","txt","rtf","md","tex","log","epub","mobi","wps","msg","wpd"] {
            map[ext] = .documents
        }
        for ext in ["py","ipynb","js","jsx","ts","tsx","html","css","scss","java","class","jar","c","cpp","h","cs","php","swift","go","rb","pl","rs","sh","bash","zsh","bat","ps1","lua","r","sql","sqlite","db","json","xml","yaml","yml","toml","ini","cfg","config","env","htaccess","gitignore","pkl","kt","dart"] {
            map[ext] = .scripts
        }
        for ext in ["jpg","jpeg","png","gif","webp","tiff","tif","bmp","heic","svg","ico","psd","ai","eps","indd","raw","cr2","nef","orf","arw","dng","xcf"] {
            map[ext] = .images
        }
        for ext in ["zip","rar","7z","tar","gz","tgz","bz2","tbz","xz","zst"] {
            map[ext] = .compressed
        }
        for ext in ["app","pkg","exe","msi","apk","xapk","ipa","apkm","deb","rpm","appx","bin","dmg"] {
            map[ext] = .programs
        }
        for ext in ["pem","crt","cer","der","p12","pfx","pki","pub","key","gpg","ovpn","asc"] {
            map[ext] = .certificates
        }
        for ext in ["mp4","mkv","mov","avi","wmv","flv","webm","m4v","mpg","mpeg","3gp","ts","vob","srt","ass"] {
            map[ext] = .videos
        }
        for ext in ["mp3","wav","aac","flac","ogg","m4a","wma","alac","mid","midi"] {
            map[ext] = .music
        }
        for ext in ["iso","ova","vdi","vbox","vmdk","qcow2","img"] {
            map[ext] = .disks
        }
        for ext in ["ttf","otf","woff","woff2"] {
            map[ext] = .fonts
        }
        map["torrent"] = .torrents
        return map
    }()
    
    private static let filenameMap: Set<String> = [
        "dockerfile","makefile","vagrantfile","jenkinsfile","procfile",
        "gemfile","rakefile","brewfile","podfile","fastfile","cartfile",
        "dangerfile","guardfile","thorfile","capfile","berksfile","cheffile",
        "puppetfile","modulefile","buildfile","gradlew","cmakelists.txt",
        "license","readme","changelog","authors","contributors","copying",
        "install","maintainers","news","thanks","todo","version"
    ]
    
    private static let skipExtensions: Set<String> = [
        "crdownload","download","part","tmp","opdownload","ds_store","localized"
    ]
    
    static func shouldSkip(extension ext: String) -> Bool {
        skipExtensions.contains(ext.lowercased())
    }
    
    static func categorize(filename: String, extension ext: String?) -> FileCategory {
        if filenameMap.contains(filename.lowercased()) { return .scripts }
        if let ext = ext, !ext.isEmpty { return extensionMap[ext.lowercased()] ?? .others }
        return .others
    }
}

// MARK: - Logger

final class Logger {
    static let shared = Logger()
    private let osLog = OSLog(subsystem: "com.user.highlycurated", category: "sorter")
    private let queue = DispatchQueue(label: "com.user.highlycurated.logger")
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()
    private let logFileURL = Config.logFile
    private let maxLogSize = Config.maxLogSize
    private let rotationFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        return df
    }()
    
    private init() {
        try? FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    
    func log(_ message: String, type: OSLogType = .info) {
        let timestamp = dateFormatter.string(from: Date())
        let formatted = "[\(timestamp)] \(message)"
        queue.async { [weak self] in
            guard let self = self else { return }
            os_log("%{public}@", log: self.osLog, type: type, formatted)
            self.writeToFile(formatted)
        }
    }
    
    func error(_ message: String) { log("ERROR: \(message)", type: .error) }
    func verbose(_ message: String, enabled: Bool) { if enabled { log("VERBOSE: \(message)") } }
    func flush() { queue.sync {} }
    
    private func writeToFile(_ message: String) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: logFileURL.path) {
                let attrs = try fm.attributesOfItem(atPath: logFileURL.path)
                if let size = attrs[.size] as? UInt64, size > maxLogSize {
                    // Timestamped rotation (cached formatter)
                    let rotatedPath = logFileURL.path + "." + rotationFormatter.string(from: Date())
                    try? fm.moveItem(atPath: logFileURL.path, toPath: rotatedPath)
                    // Enforce retention policy
                    cleanupOldLogs()
                }
            }
            let data = (message + "\n").data(using: .utf8) ?? Data()
            if fm.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logFileURL, options: .atomic)
            }
        } catch {
            os_log("Logger write failed: %{public}@", log: osLog, type: .error, error.localizedDescription)
        }
    }
    
    private func cleanupOldLogs() {
        let fm = FileManager.default
        let logDir = logFileURL.deletingLastPathComponent()
        let baseName = logFileURL.lastPathComponent
        guard let files = try? fm.contentsOfDirectory(atPath: logDir.path) else { return }
        // Find rotated logs matching pattern: basename.YYYYMMDD_HHMMSS
        let rotated = files.filter { $0.hasPrefix(baseName + ".") && $0.count > baseName.count + 1 }
            .sorted().reversed()  // Newest first
        let toDelete = rotated.dropFirst(Config.logRetentionCount)
        for file in toDelete {
            try? fm.removeItem(atPath: logDir.appendingPathComponent(file).path)
        }
    }
}

// MARK: - Process Utilities (Darwin-specific)

/// Get process start time using sysctl (Darwin)
func getProcessStartTime(pid: pid_t) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
    
    let startSec = info.kp_proc.p_starttime.tv_sec
    let startUsec = info.kp_proc.p_starttime.tv_usec
    return Date(timeIntervalSince1970: Double(startSec) + Double(startUsec) / 1_000_000)
}

/// Check if path is on network filesystem (NFS, SMB, AFP)
func isNetworkFilesystem(path: String) -> Bool {
    var stat = statfs()
    guard statfs(path, &stat) == 0 else { return false }
    // Safe extraction of f_fstypename (fixed-size tuple to String)
    let fsType = withUnsafeBytes(of: stat.f_fstypename) { buf in
        buf.withMemoryRebound(to: CChar.self) {
            String(cString: $0.baseAddress!)
        }
    }
    let networkTypes = ["nfs", "smbfs", "afpfs", "webdav", "cifs"]
    return networkTypes.contains(fsType.lowercased())
}

// MARK: - File Lock (flock + PID + StartTime verification)

final class FileLock {
    private var fd: Int32 = -1
    private let path: String
    
    init(path: String) { self.path = path }
    
    func acquire() -> Bool {
        fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            Logger.shared.error("Cannot create lock file at \(path)")
            return false
        }
        
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // Lock held - check if stale using PID + start time
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = trimmed.split(separator: ":")
                if let pidStr = parts.first, let pid = Int32(pidStr) {
                    // Check if process exists
                    if kill(pid, 0) != 0 && errno == ESRCH {
                        return cleanupAndRetry(reason: "pid \(pid) dead")
                    }
                    
                    // Process exists - verify start time if available
                    if parts.count > 1 {
                        let startPart = String(parts[1])
                        if startPart == "unknown" {
                            // pid:unknown - conservative approach: wait briefly and recheck
                            Logger.shared.log("Lock has unknown startTime, waiting to verify...")
                            usleep(100_000) // 100ms
                            if kill(pid, 0) != 0 && errno == ESRCH {
                                return cleanupAndRetry(reason: "pid \(pid) died during wait")
                            }
                            // Still alive after wait - treat as valid
                        } else if let storedTime = Double(startPart), storedTime > 0,
                                  let actualTime = getProcessStartTime(pid: pid) {
                            let storedDate = Date(timeIntervalSince1970: storedTime)
                            if abs(actualTime.timeIntervalSince(storedDate)) > 1.0 {
                                return cleanupAndRetry(reason: "pid \(pid) reused (start time mismatch)")
                            }
                        }
                    }
                }
            }
            Logger.shared.log("Another instance running, exiting")
            close(fd); fd = -1
            return false
        }
        
        writeLockInfo()
        Logger.shared.log("Lock acquired (pid \(getpid()))")
        return true
    }
    
    private func cleanupAndRetry(reason: String) -> Bool {
        Logger.shared.log("Stale lock: \(reason). Cleaning...")
        close(fd)
        do {
            // Log file attributes for debugging permission issues
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            Logger.shared.log("Lock file attrs: owner=\(owner), perms=\(String(perms, radix: 8))")
            try FileManager.default.removeItem(atPath: path)
        } catch let error as NSError {
            Logger.shared.error("Failed to remove stale lock: \(error.localizedDescription)")
            // Actionable suggestion for operators
            if error.code == NSFileWriteNoPermissionError || error.code == NSFileReadNoPermissionError {
                Logger.shared.log("Suggestion: Check lock file ownership. Run as file owner or remove manually: rm \(path)")
            }
            // Continue anyway - flock might still work
        }
        fd = open(path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0 {
            writeLockInfo()
            Logger.shared.log("Lock acquired after cleanup (pid \(getpid()))")
            return true
        }
        Logger.shared.log("Failed to acquire lock after cleanup")
        close(fd); fd = -1
        return false
    }
    
    private func writeLockInfo() {
        // Write PID:startTime or PID:unknown to lock file
        let pid = getpid()
        let content: String
        if let startTime = getProcessStartTime(pid: pid) {
            content = "\(pid):\(startTime.timeIntervalSince1970)"
        } else {
            content = "\(pid):unknown"  // Sentinel for unavailable startTime
            // Schedule async enrich attempt
            enrichLockInfoAsync()
        }
        content.withCString {
            ftruncate(fd, 0)
            lseek(fd, 0, SEEK_SET)
            _ = Darwin.write(fd, $0, strlen($0))
            fsync(fd)  // Ensure durability on crash
        }
    }
    
    /// Async attempt to enrich lock file with startTime if initially unavailable
    private func enrichLockInfoAsync() {
        let lockFd = fd
        let lockPid = getpid()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
            guard let startTime = getProcessStartTime(pid: lockPid) else { return }
            let content = "\(lockPid):\(startTime.timeIntervalSince1970)"
            content.withCString {
                ftruncate(lockFd, 0)
                lseek(lockFd, 0, SEEK_SET)
                _ = Darwin.write(lockFd, $0, strlen($0))
                fsync(lockFd)
            }
            Logger.shared.verbose("Lock file enriched with startTime", enabled: true)
        }
    }
    
    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        try? FileManager.default.removeItem(atPath: path)
        Logger.shared.log("Lock released")
        fd = -1
    }
    
    deinit { release() }
}

// MARK: - Signal Manager

final class SignalManager {
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    private var prevSigint: sig_t?
    private var prevSigterm: sig_t?
    
    func setup(shutdownHandler: @escaping () -> Void) {
        // Save previous handlers and ignore signals (required for DispatchSource on Darwin)
        prevSigint = signal(SIGINT, SIG_IGN)
        prevSigterm = signal(SIGTERM, SIG_IGN)
        
        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource?.setEventHandler {
            Logger.shared.log("SIGINT — shutting down")
            shutdownHandler()
        }
        sigintSource?.resume()
        
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler {
            Logger.shared.log("SIGTERM — shutting down")
            shutdownHandler()
        }
        sigtermSource?.resume()
    }
    
    func restore() {
        sigintSource?.cancel()
        sigtermSource?.cancel()
        // Restore previous handlers
        if let prev = prevSigint { signal(SIGINT, prev) }
        if let prev = prevSigterm { signal(SIGTERM, prev) }
    }
}

// MARK: - File Processor

final class FileProcessor {
    private let fm = FileManager.default
    private let downloadsURL: URL
    private let verbose: Bool
    private let maxRetries: Int
    
    init(verbose: Bool = false) {
        self.downloadsURL = Config.downloadsDir
        self.verbose = verbose
        self.maxRetries = Config.maxMoveRetries
    }
    
    func run() {
        // Security: verify directory ownership (optional hardening)
        do {
            let attrs = try fm.attributesOfItem(atPath: downloadsURL.path)
            if let owner = attrs[.ownerAccountID] as? NSNumber {
                if owner.uint32Value != getuid() {
                    Logger.shared.error("Downloads dir not owned by current user (uid \(getuid()))")
                    return
                }
            }
        } catch {
            Logger.shared.error("Cannot verify Downloads ownership: \(error.localizedDescription)")
        }
        
        // Warn if running on network filesystem (NFS, SMB, etc.)
        if isNetworkFilesystem(path: downloadsURL.path) {
            Logger.shared.log("WARNING: Running on network filesystem. flock/atomic operations may not be reliable.")
        }
        
        do {
            let contents = try fm.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey, .isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants])
            
            let files = contents.filter { url in
                do {
                    let vals = try url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey, .isSymbolicLinkKey])
                    if vals.isSymbolicLink == true {
                        Logger.shared.verbose("Skip symlink: \(url.lastPathComponent)", enabled: verbose)
                        return false
                    }
                    guard let isFile = vals.isRegularFile, isFile else { return false }
                    if let isHidden = vals.isHidden, isHidden {
                        Logger.shared.verbose("Skip hidden: \(url.lastPathComponent)", enabled: verbose)
                        return false
                    }
                    return true
                } catch {
                    Logger.shared.log("Skip (attr error): \(url.lastPathComponent)")
                    return false
                }
            }
            
            if files.isEmpty {
                Logger.shared.verbose("No files to process", enabled: verbose)
                return
            }
            
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "com.user.highlycurated.processor", attributes: .concurrent)
            var count = 0
            let countLock = NSLock()
            
            for fileURL in files {
                group.enter()
                queue.async { [weak self] in
                    defer { group.leave() }
                    if self?.processFile(fileURL) == true {
                        countLock.lock(); count += 1; countLock.unlock()
                    }
                }
            }
            group.wait()
            Logger.shared.log("Sort completed. Processed \(count) file(s).")
        } catch {
            Logger.shared.error("Cannot read Downloads: \(error.localizedDescription)")
        }
    }
    
    private func processFile(_ sourceURL: URL) -> Bool {
        let filename = sourceURL.lastPathComponent
        
        if filename.hasPrefix(".") {
            Logger.shared.verbose("Skip hidden (dot prefix): \(filename)", enabled: verbose)
            return false
        }
        
        let ext = sourceURL.pathExtension
        if !ext.isEmpty && FileCategory.shouldSkip(extension: ext) {
            Logger.shared.verbose("Skip incomplete: \(filename)", enabled: verbose)
            return false
        }
        
        let category = FileCategory.categorize(filename: filename, extension: ext.isEmpty ? nil : ext)
        let destDir = downloadsURL.appendingPathComponent(category.rawValue, isDirectory: true)
        
        do {
            if !fm.fileExists(atPath: destDir.path) {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            }
        } catch {
            Logger.shared.error("Cannot create dir: \(destDir.path) — \(error.localizedDescription)")
            return false
        }
        
        do {
            let vals = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if vals.isSymbolicLink == true {
                Logger.shared.verbose("Skip symlink (pre-move): \(filename)", enabled: verbose)
                return false
            }
            guard let isFile = vals.isRegularFile, isFile else {
                Logger.shared.verbose("Skip non-file (pre-move): \(filename)", enabled: verbose)
                return false
            }
        } catch {
            Logger.shared.verbose("Skip (attr error pre-move): \(filename)", enabled: verbose)
            return false
        }
        
        return atomicMoveWithRetry(source: sourceURL, destDir: destDir, filename: filename, category: category.rawValue)
    }
    
    private func atomicMoveWithRetry(source: URL, destDir: URL, filename: String, category: String) -> Bool {
        let ext = (filename as NSString).pathExtension
        let name = (filename as NSString).deletingPathExtension
        var counter = 1
        
        while counter <= maxRetries {
            // Log progress every 10 retries (hot directory indicator)
            if counter > 1 && counter % 10 == 0 {
                Logger.shared.log("Retry \(counter)/\(maxRetries) for \(filename)")
            }
            // Exponential backoff after 5 retries to avoid hot-loop
            if counter > 5 {
                usleep(useconds_t(min(counter * 200, 10000)))  // 200µs * counter, max 10ms
            }
            
            let targetName: String
            if counter == 1 {
                targetName = filename
            } else {
                targetName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            }
            let target = destDir.appendingPathComponent(targetName)
            
            do {
                try fm.moveItem(at: source, to: target)
                Logger.shared.log("Moved: \(filename) -> \(category)/\(targetName)")
                return true
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                    counter += 1
                    continue
                }
                if error.domain == NSPOSIXErrorDomain && error.code == EXDEV {
                    do {
                        try fm.copyItem(at: source, to: target)
                        try fm.removeItem(at: source)
                        Logger.shared.log("Moved (cross-volume): \(filename) -> \(category)/\(targetName)")
                        return true
                    } catch {
                        Logger.shared.error("Copy+remove failed for \(filename): \(error.localizedDescription)")
                        return false
                    }
                }
                if !fm.fileExists(atPath: source.path) {
                    Logger.shared.verbose("Source vanished: \(filename)", enabled: verbose)
                    return false
                }
                Logger.shared.error("Move failed for \(filename): \(error.localizedDescription)")
                return false
            }
        }
        Logger.shared.error("Max retries (\(maxRetries)) exceeded for \(filename)")
        return false
    }
}

// MARK: - Main Entry Point

@main
struct HighlyCurated {
    static func main() {
        let args = CommandLine.arguments
        let verbose = args.contains("--verbose") || ProcessInfo.processInfo.environment["HIGHLYCURATED_VERBOSE"] == "1"
        
        let lock = FileLock(path: Config.lockFile.path)
        guard lock.acquire() else {
            // Exit with non-zero code for automation/CI
            exit(2)
        }
        
        let signals = SignalManager()
        signals.setup {
            Logger.shared.flush()
            signals.restore()
            lock.release()
            exit(0)
        }
        
        FileProcessor(verbose: verbose).run()
        
        Logger.shared.flush()
        signals.restore()
        lock.release()
    }
}
