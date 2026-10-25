import AppKit
import CryptoKit
import Foundation

struct ReleaseInfo: Equatable {
    let version: String
    let notes: String
    let pageURL: URL
    let zipURL: URL
    let signatureURL: URL
}

enum UpdateError: LocalizedError {
    case http(Int)
    case noReleases
    case missingAssets
    case badSignature
    case invalidBundle(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "GitHub returned \(code) while checking for updates."
        case .noReleases: return "No releases have been published yet."
        case .missingAssets: return "The latest release has no downloadable app."
        case .badSignature: return "The downloaded update failed its signature check and was discarded."
        case .invalidBundle(let why): return "The downloaded update is not valid: \(why)"
        case .install(let why): return "Couldn't install the update: \(why)"
        }
    }
}

/// Checks GitHub Releases for a newer version and installs it in place.
///
/// Each release ships `Vaporwatch.zip` plus `Vaporwatch.zip.sig`, an Ed25519 signature made with a
/// private key that never leaves the maintainer's Mac (see scripts/sign-update.swift). The app
/// only installs an archive whose signature verifies against the public key below.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        /// The repository has no published release yet (GitHub answers 404), so there is nothing to compare against.
        case noReleases
        case available(ReleaseInfo)
        case installing(String)
        case failed(String)
    }

    static let repository = "mrte1122/Vaporwatch"
    static let publicKey = "weUiF6oi+0Pn/7LmKFhKdONfX4Y7DSHKxquUt5WNG48="
    static let zipName = "Vaporwatch.zip"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!

    /// Why an in-place update can't work from where this copy is running, or nil if it can.
    /// The common case: the app was opened straight from Downloads, so macOS runs it from a
    /// read-only "App Translocation" copy that can't be replaced.
    nonisolated static var installLocationProblem: String? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return "Vaporwatch isn't running from an app bundle." }
        if isTranslocated {
            return "macOS is running a temporary, read-only copy of Vaporwatch because it wasn't moved out of the folder it was downloaded to."
        }
        if installMode == nil {
            return "This account can't change apps in this folder, so updates need an administrator or a manual download."
        }
        return nil
    }

    /// Opened straight from Downloads: macOS runs a read-only "App Translocation" copy.
    nonisolated static var isTranslocated: Bool { Bundle.main.bundleURL.path.contains("/AppTranslocation/") }

    /// While running translocated: a copy the user has since moved into an Applications folder,
    /// so the banner can offer to relaunch from there instead of repeating "move it".
    nonisolated static var movedCopyURL: URL? {
        guard isTranslocated else { return nil }
        let candidates = ["/Applications/Vaporwatch.app", NSString(string: "~/Applications/Vaporwatch.app").expandingTildeInPath]
        return candidates.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/Vaporwatch").path) }
    }

    enum InstallMode {
        /// Swap the whole bundle (the folder holding it is writable).
        case replaceBundle
        /// Swap only Contents/. A standard (non-admin) user can't write to /Applications itself,
        /// but owns the Vaporwatch.app they put there, so its contents can still be replaced.
        case replaceContents
    }

    nonisolated static var installMode: InstallMode? {
        let fm = FileManager.default
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app", !isTranslocated else { return nil }
        if fm.isWritableFile(atPath: url.deletingLastPathComponent().path) { return .replaceBundle }
        if fm.isWritableFile(atPath: url.path), fm.isWritableFile(atPath: url.appendingPathComponent("Contents").path) {
            return .replaceContents
        }
        return nil
    }

    /// Opens the moved copy and quits this translocated one.
    static func relaunchFromMovedCopy() {
        guard let target = movedCopyURL else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", target.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: SettingsKey.lastUpdateCheck) as? Date

    var notifier: Notifier?
    private var timer: Timer?

    var availableRelease: ReleaseInfo? {
        if case .available(let r) = state { return r }
        return nil
    }

    /// One check shortly after launch, then at most once a day.
    func start() {
        guard !Demo.isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            Task { @MainActor in await self?.automaticCheck(force: true) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.automaticCheck(force: false) }
        }
    }

    private func automaticCheck(force: Bool) async {
        guard UserDefaults.standard.bool(forKey: SettingsKey.autoUpdateCheck) else { return }
        if !force, let last = lastChecked, Date().timeIntervalSince(last) < 86_400 { return }
        if case .installing = state { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: SettingsKey.lastUpdateCheck)
            if Self.isVersion(release.version, newerThan: Self.currentVersion) {
                state = .available(release)
                announce(release)
            } else {
                state = .upToDate
            }
        } catch UpdateError.noReleases {
            // Nothing published yet: not a failure, so no banner; Settings and --check-update say so.
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: SettingsKey.lastUpdateCheck)
            state = .noReleases
        } catch {
            // Background checks fail quietly (offline, rate-limited); manual checks report why.
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// One notification per new version, ever.
    private func announce(_ release: ReleaseInfo) {
        let key = SettingsKey.notifiedUpdateVersion
        guard UserDefaults.standard.string(forKey: key) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: key)
        notifier?.post(title: "Vaporwatch \(release.version) is available",
                       body: "Open Vaporwatch from the menu bar to install it.")
    }

    // MARK: - GitHub

    static func fetchLatest() async throws -> ReleaseInfo {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Release: Decodable { let tag_name: String; let html_url: URL; let body: String?; let assets: [Asset] }

        // Unauthenticated on purpose: release metadata is public, so no token is sent.
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Vaporwatch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 404 { throw UpdateError.noReleases }
        guard code == 200 else { throw UpdateError.http(code) }

        let r = try JSONDecoder().decode(Release.self, from: data)
        guard let zip = r.assets.first(where: { $0.name == zipName }),
              let sig = r.assets.first(where: { $0.name == zipName + ".sig" }) else { throw UpdateError.missingAssets }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return ReleaseInfo(version: version, notes: r.body ?? "", pageURL: r.html_url,
                           zipURL: zip.browser_download_url, signatureURL: sig.browser_download_url)
    }

    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Install

    /// Downloads, verifies, swaps the app bundle in place, and relaunches.
    /// `relaunch` is false for the `--update` CLI mode, which just exits afterwards.
    func install(_ release: ReleaseInfo, relaunch: Bool = true) async {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("VaporwatchUpdate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        do {
            let current = Bundle.main.bundleURL
            if let problem = Self.installLocationProblem {
                throw UpdateError.install("\(problem) Move Vaporwatch to Applications, open it from there, and try again.")
            }
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            state = .installing("Downloading \(release.version)…")
            let (zipData, zipResp) = try await URLSession.shared.data(from: release.zipURL)
            let (sigData, sigResp) = try await URLSession.shared.data(from: release.signatureURL)
            for resp in [zipResp, sigResp] {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard code == 200 else { throw UpdateError.http(code) }
            }

            state = .installing("Verifying…")
            try Self.verify(zipData, signature: sigData)
            let zipFile = work.appendingPathComponent(Self.zipName)
            try zipData.write(to: zipFile)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.path])
            // Releases from 0.6.0 also ship a Steamwatch.zip/Steamwatch.app copy for installs from before
            // the rename; accept whichever the archive holds.
            guard let newApp = ["Vaporwatch.app", "Steamwatch.app"].map({ work.appendingPathComponent($0) })
                .first(where: { fm.fileExists(atPath: $0.path) }) else { throw UpdateError.invalidBundle("no app in the archive") }
            try await Self.validate(newApp, expectedVersion: release.version)

            state = .installing("Installing…")
            _ = try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            do {
                switch Self.installMode {
                case .replaceContents:
                    _ = try fm.replaceItemAt(current.appendingPathComponent("Contents"),
                                             withItemAt: newApp.appendingPathComponent("Contents"))
                default:
                    _ = try fm.replaceItemAt(current, withItemAt: newApp)
                }
            } catch {
                throw UpdateError.install("\(error.localizedDescription) Download it manually from the releases page instead.")
            }

            // An install from before the rename still sits at …/Steamwatch.app: give it the new name.
            var installed = current
            let renamed = current.deletingLastPathComponent().appendingPathComponent("Vaporwatch.app")
            if current.lastPathComponent != "Vaporwatch.app", Self.installMode == .replaceBundle,
               !fm.fileExists(atPath: renamed.path), (try? fm.moveItem(at: current, to: renamed)) != nil {
                installed = renamed
            }

            state = .installing("Restarting…")
            if relaunch { Self.relaunch(installed) }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    static func verify(_ data: Data, signature sigData: Data) throws {
        let text = String(decoding: sigData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sig = Data(base64Encoded: text),
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(sig, for: data) else { throw UpdateError.badSignature }
    }

    private static func validate(_ app: URL, expectedVersion: String) async throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) else { throw UpdateError.invalidBundle("no Info.plist") }
        guard plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidBundle("unexpected bundle identifier")
        }
        guard plist["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw UpdateError.invalidBundle("version doesn't match the release")
        }
        do {
            try await run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        } catch {
            throw UpdateError.invalidBundle("code signature is broken")
        }
        // Once this copy is signed with a Developer ID, only accept updates from the same team.
        // (Ad-hoc builds have no team, so the first move to a Developer ID build is allowed.)
        if let team = teamIdentifier(of: Bundle.main.bundleURL) {
            guard teamIdentifier(of: app) == team else {
                throw UpdateError.invalidBundle("it isn't signed by the same developer")
            }
        }
    }

    /// The signing team from `codesign -dv`, or nil for ad-hoc / unsigned code.
    nonisolated static func teamIdentifier(of app: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dv", app.path]
        let pipe = Pipe()
        p.standardError = pipe          // codesign -dv writes its report to stderr
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { return nil }
        let team = String(line.dropFirst("TeamIdentifier=".count))
        return team == "not set" || team.isEmpty ? nil : team
    }

    private static func relaunch(_ app: URL) {
        // A detached shell outlives this process, waits for it to quit, then reopens the new bundle.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume(returning: 0)
                } else {
                    cont.resume(throwing: UpdateError.install("\((tool as NSString).lastPathComponent) exited with \(proc.terminationStatus)"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
