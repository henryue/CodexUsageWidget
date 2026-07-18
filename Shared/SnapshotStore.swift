import Foundation
import Darwin

public protocol UsageSnapshotStoring: Sendable {
    func loadResult() -> SnapshotStoreLoadResult
    func load() -> SharedUsageEnvelope?
    func save(_ envelope: SharedUsageEnvelope) throws
}

public struct AppGroupSnapshotStore: UsageSnapshotStoring, Sendable {
    public static let suiteInfoKey = "CodexUsageAppGroupIdentifier"
    public static var suiteName: String? {
        validatedSuiteName(Bundle.main.object(forInfoDictionaryKey: suiteInfoKey) as? String)
    }

    public static func validatedSuiteName(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-")
        )
        guard !value.isEmpty,
              value.contains("."),
              !value.contains("$("),
              value.rangeOfCharacter(from: allowedCharacters.inverted) == nil else {
            return nil
        }
        return value
    }
    private static let snapshotFilename = "codex-usage-snapshot-v1.json"
    private let overrideDirectoryURL: URL?
    private let resolveAppGroupWhenNeeded: Bool
    private let atomicWriter: @Sendable (Data, URL) throws -> Void
    private let recoveryWriter: @Sendable (Data, URL) throws -> Void
    private let snapshotRemover: @Sendable (URL) throws -> Void
    private let emergencyInvalidator: @Sendable (Data, URL) throws -> Void

    // The host app is the only expected writer. Serializing the complete
    // publication transaction also keeps concurrent test calls and any other
    // same-process caller from racing an emergency in-place invalidation with
    // a sibling atomic replacement. This is intentionally not a cross-process
    // lock; normal macOS app launches use one host-app process.
    private static let publicationLock = NSLock()

    public init() {
        self.overrideDirectoryURL = nil
        self.resolveAppGroupWhenNeeded = true
        self.atomicWriter = Self.defaultAtomicWriter
        self.recoveryWriter = Self.defaultAtomicWriter
        self.snapshotRemover = Self.defaultSnapshotRemover
        self.emergencyInvalidator = Self.defaultEmergencyInvalidator
    }

    public init(directoryURL: URL) {
        self.overrideDirectoryURL = directoryURL
        self.resolveAppGroupWhenNeeded = false
        self.atomicWriter = Self.defaultAtomicWriter
        self.recoveryWriter = Self.defaultAtomicWriter
        self.snapshotRemover = Self.defaultSnapshotRemover
        self.emergencyInvalidator = Self.defaultEmergencyInvalidator
    }

    init(
        directoryURL: URL,
        atomicWriter: @escaping @Sendable (Data, URL) throws -> Void,
        recoveryWriter: @escaping @Sendable (Data, URL) throws -> Void = Self.defaultAtomicWriter,
        snapshotRemover: @escaping @Sendable (URL) throws -> Void = Self.defaultSnapshotRemover,
        emergencyInvalidator: @escaping @Sendable (Data, URL) throws -> Void = Self.defaultEmergencyInvalidator
    ) {
        self.overrideDirectoryURL = directoryURL
        self.resolveAppGroupWhenNeeded = false
        self.atomicWriter = atomicWriter
        self.recoveryWriter = recoveryWriter
        self.snapshotRemover = snapshotRemover
        self.emergencyInvalidator = emergencyInvalidator
    }

    init(unavailableForTesting: Void) {
        self.overrideDirectoryURL = nil
        self.resolveAppGroupWhenNeeded = false
        self.atomicWriter = Self.defaultAtomicWriter
        self.recoveryWriter = Self.defaultAtomicWriter
        self.snapshotRemover = Self.defaultSnapshotRemover
        self.emergencyInvalidator = Self.defaultEmergencyInvalidator
    }

    public func load() -> SharedUsageEnvelope? {
        guard case .loaded(let envelope) = loadResult() else { return nil }
        return envelope
    }

    public func loadResult() -> SnapshotStoreLoadResult {
        guard let fileURL = snapshotURL() else { return .unavailable }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .unavailable
        }
        do {
            return .loaded(try JSONDecoder.codexUsage.decode(SharedUsageEnvelope.self, from: data))
        } catch {
            return .invalid
        }
    }

    public func save(_ envelope: SharedUsageEnvelope) throws {
        Self.publicationLock.lock()
        defer { Self.publicationLock.unlock() }
        try saveLocked(envelope)
    }

    private func saveLocked(_ envelope: SharedUsageEnvelope) throws {
        guard let fileURL = snapshotURL() else { throw SnapshotStoreError.appGroupUnavailable }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.codexUsage.encode(envelope)
            // Data.write(.atomic) writes a sibling temporary file and replaces
            // the destination only after the bytes are complete, so the Widget
            // never observes a partially-written JSON document.
            try atomicWriter(data, fileURL)
        } catch {
            // Preserve actionable cached values, but never leave either the
            // attempted or an older envelope looking ready after publication
            // failed. This second, minimal atomic write is deliberately a
            // separate recovery path so transient primary-writer failures can
            // still publish an explicit stale state.
            let recovery = Self.recoveryEnvelope(from: envelope)
            let recoveryData = (try? JSONEncoder.codexUsage.encode(recovery))
                ?? Self.minimalFailedRecoveryData
            do {
                try recoveryWriter(recoveryData, fileURL)
            } catch {
                // If even the stale recovery write is unavailable, remove this
                // one exact generated file so the Widget cannot re-read an old
                // ready value. A missing state is safer than fabricated usage.
                do {
                    try invalidateExistingSnapshot(at: fileURL)
                } catch {
                    // Directory permissions can prohibit rename/remove while
                    // the existing regular file itself remains writable. The
                    // emergency path therefore revokes the old JSON in-place
                    // before it writes any replacement bytes. Until the final
                    // one-byte commit the file is intentionally invalid JSON;
                    // after commit it can decode only as the recovery envelope,
                    // whose serviceStatus is never `available`.
                    do {
                        try emergencyInvalidator(recoveryData, fileURL)
                    } catch {
                        throw SnapshotStoreError.writeRecoveryAndInvalidationFailed
                    }
                    throw SnapshotStoreError.writeFailedRecoveredAsStale
                }
                throw SnapshotStoreError.writeFailed
            }
            throw SnapshotStoreError.writeFailedRecoveredAsStale
        }
    }

    private static func recoveryEnvelope(
        from attempted: SharedUsageEnvelope
    ) -> SharedUsageEnvelope {
        if attempted.serviceStatus != .available {
            return attempted
        }
        return SharedUsageEnvelope(
            snapshot: attempted.snapshot,
            serviceStatus: .failed,
            lastAttemptAt: attempted.lastAttemptAt,
            message: "Shared usage could not be updated. Open the app to refresh."
        )
    }

    // JSONEncoder cannot normally fail for SharedUsageEnvelope, but the
    // emergency path must itself remain available even if that assumption is
    // invalidated by a future model change. This is a complete, non-ready v1
    // envelope and therefore a safe final commit payload.
    private static let minimalFailedRecoveryData = Data(
        #"{"schemaVersion":1,"snapshot":null,"serviceStatus":"failed","lastAttemptAt":0,"message":"Shared usage is unavailable. Open the app to refresh."}"#.utf8
    )

    private static var defaultAtomicWriter: @Sendable (Data, URL) throws -> Void {
        { data, fileURL in
            try data.write(to: fileURL, options: [.atomic])
        }
    }

    private static var defaultSnapshotRemover: @Sendable (URL) throws -> Void {
        { fileURL in
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private static var defaultEmergencyInvalidator: @Sendable (Data, URL) throws -> Void {
        { recoveryData, fileURL in
            try emergencyInvalidateInPlace(recoveryData: recoveryData, at: fileURL)
        }
    }

    private func invalidateExistingSnapshot(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try snapshotRemover(fileURL)
        } catch {
            throw SnapshotStoreError.invalidationFailed
        }
    }

    /// Fail-closed single-file recovery for the narrow case where both atomic
    /// replacements and removal fail but the existing inode is still writable.
    ///
    /// Commit protocol:
    /// 1. overwrite byte zero with a non-JSON sentinel and fsync it;
    /// 2. write bytes 1...N of the non-ready recovery envelope, truncate, fsync;
    /// 3. replace the sentinel with `{` and fsync the committed stale payload.
    ///
    /// A crash or error after step 1 and before step 3 leaves invalid JSON. A
    /// failure during/after step 3 can expose only the recovery envelope, never
    /// the older `available` envelope. The descriptor is deliberately scoped
    /// to this call, opened close-on-exec, and never retained across an atomic
    /// inode replacement.
    private static func emergencyInvalidateInPlace(
        recoveryData: Data,
        at fileURL: URL
    ) throws {
        guard recoveryData.count > 1, recoveryData.first == 0x7B else {
            throw SnapshotStoreError.invalidationFailed
        }

        let descriptor = try openEmergencyDescriptor(at: fileURL)
        defer { _ = Darwin.close(descriptor) }

        var invalidSentinel: UInt8 = 0
        try withUnsafeBytes(of: &invalidSentinel) { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw SnapshotStoreError.invalidationFailed
            }
            try writeAll(
                descriptor: descriptor,
                bytes: baseAddress,
                count: bytes.count,
                offset: 0
            )
        }
        try synchronize(descriptor: descriptor)

        try recoveryData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw SnapshotStoreError.invalidationFailed
            }
            try writeAll(
                descriptor: descriptor,
                bytes: baseAddress.advanced(by: 1),
                count: bytes.count - 1,
                offset: 1
            )
        }
        try truncate(descriptor: descriptor, to: recoveryData.count)
        try synchronize(descriptor: descriptor)

        var commitByte: UInt8 = 0x7B
        try withUnsafeBytes(of: &commitByte) { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw SnapshotStoreError.invalidationFailed
            }
            try writeAll(
                descriptor: descriptor,
                bytes: baseAddress,
                count: bytes.count,
                offset: 0
            )
        }
        try synchronize(descriptor: descriptor)
    }

    private static func openEmergencyDescriptor(at fileURL: URL) throws -> Int32 {
        while true {
            let descriptor = fileURL.path.withCString {
                Darwin.open($0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            if descriptor >= 0 {
                var status = stat()
                while Darwin.fstat(descriptor, &status) != 0 {
                    if errno == EINTR { continue }
                    let error = currentPOSIXError()
                    _ = Darwin.close(descriptor)
                    throw error
                }
                guard status.st_mode & S_IFMT == S_IFREG else {
                    _ = Darwin.close(descriptor)
                    throw POSIXError(.EINVAL)
                }

                var descriptorFlags: Int32
                repeat {
                    descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
                } while descriptorFlags < 0 && errno == EINTR
                guard descriptorFlags >= 0, descriptorFlags & FD_CLOEXEC != 0 else {
                    let error = descriptorFlags < 0
                        ? currentPOSIXError()
                        : POSIXError(.EINVAL)
                    _ = Darwin.close(descriptor)
                    throw error
                }
                return descriptor
            }
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
    }

    private static func writeAll(
        descriptor: Int32,
        bytes: UnsafeRawPointer,
        count: Int,
        offset: Int
    ) throws {
        var written = 0
        while written < count {
            let result = Darwin.pwrite(
                descriptor,
                bytes.advanced(by: written),
                count - written,
                off_t(offset + written)
            )
            if result > 0 {
                written += result
                continue
            }
            if result < 0, errno == EINTR { continue }
            throw result == 0 ? POSIXError(.EIO) : currentPOSIXError()
        }
    }

    private static func truncate(descriptor: Int32, to byteCount: Int) throws {
        while Darwin.ftruncate(descriptor, off_t(byteCount)) != 0 {
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
    }

    private static func synchronize(descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func snapshotURL() -> URL? {
        let directory: URL?
        if let overrideDirectoryURL {
            directory = overrideDirectoryURL
        } else if resolveAppGroupWhenNeeded {
            guard let suiteName = Self.suiteName else { return nil }
            directory = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: suiteName
            )
        } else {
            directory = nil
        }
        return directory?.appendingPathComponent(Self.snapshotFilename, isDirectory: false)
    }
}

public enum SnapshotStoreLoadResult: Equatable, Sendable {
    case missing
    case loaded(SharedUsageEnvelope)
    case invalid
    case unavailable
}

public enum SnapshotStoreError: Error, LocalizedError, Equatable, Sendable {
    case appGroupUnavailable
    case writeFailed
    case writeFailedRecoveredAsStale
    case invalidationFailed
    case writeRecoveryAndInvalidationFailed

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The App Group is unavailable. Check signing and entitlements."
        case .writeFailed:
            "The shared usage snapshot could not be published."
        case .writeFailedRecoveredAsStale:
            "The shared usage snapshot was recovered as stale."
        case .invalidationFailed, .writeRecoveryAndInvalidationFailed:
            "The shared usage snapshot could not be safely invalidated."
        }
    }
}

private extension JSONEncoder {
    static var codexUsage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var codexUsage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
