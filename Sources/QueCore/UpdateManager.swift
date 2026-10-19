// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

/// Manages checking for GitHub Releases, downloading, and auto-updating CursorDeck in-place.
public final class UpdateManager {
    public static let shared = UpdateManager()

    public static let currentVersion = "2.11.0"
    public static let repoOwner = "spandanmahajan-rgb"
    public static let repoName = "que"

    private let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!

    private var isChecking = false
    private var periodicTimer: Timer?
    /// Background checks run at most this often. Was 24 h: a release then took up to a day to light the blue dot
    /// (users only saw it after choosing Check for Updates). Hourly is far inside GitHub's 60 requests/hour limit.
    static let backgroundCheckInterval: TimeInterval = 3600

    /// Posted on the main queue whenever `availableVersion` changes (menu bar dot, Control Center, quick menu).
    public static let availabilityDidChange = Notification.Name("QueUpdateAvailabilityDidChange")
    private static let availableVersionKey = "Que_availableUpdateVersion"

    /// A newer version found by any check, remembered across launches (a background check runs at most once an hour),
    /// or nil when Que is up to date. Shown as a blue dot in the menu bar icon; nothing pops up on its own.
    public private(set) var availableVersion: String? = {
        guard let stored = UserDefaults.standard.string(forKey: availableVersionKey),
              UpdateManager.compare(stored, currentVersion) > 0 else { return nil }
        return stored
    }()

    private func setAvailableVersion(_ version: String?) {
        guard version != availableVersion else { return }
        availableVersion = version
        if let version = version {
            UserDefaults.standard.set(version, forKey: Self.availableVersionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.availableVersionKey)
        }
        NotificationCenter.default.post(name: Self.availabilityDidChange, object: self)
    }

    /// Checks shortly after launch, then keeps checking while Que runs (people rarely quit a menu bar app), and when the
    /// Control Center opens. Each background check is throttled to once an hour.
    public func startBackgroundChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.checkForUpdates(userInitiated: false)
        }
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: Self.backgroundCheckInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
        periodicTimer?.tolerance = 600
    }

    private init() {}

    /// Checks GitHub for new releases.
    /// - Parameter userInitiated: If true, shows an alert when already up-to-date or on error. If false, fails silently.
    public func checkForUpdates(userInitiated: Bool) {
        if !userInitiated {
            // Background check: throttle to at most once an hour (backgroundCheckInterval)
            let lastCheck = UserDefaults.standard.double(forKey: "CursorDeck_lastBackgroundCheck")
            let now = Date().timeIntervalSince1970
            if now - lastCheck < Self.backgroundCheckInterval - 60 {
                return
            }
        }

        guard !isChecking else { return }
        isChecking = true

        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Que-App", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChecking = false

                if !userInitiated {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "CursorDeck_lastBackgroundCheck")
                }

                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    if userInitiated {
                        self.showAlert(
                            title: "Couldn't check for updates",
                            message: "Make sure you're connected to the internet, then try again.",
                            button: "OK"
                        )
                    }
                    return
                }

                self.handleReleaseResponse(json, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handleReleaseResponse(_ json: [String: Any], userInitiated: Bool) {
        guard let tagName = json["tag_name"] as? String else {
            if userInitiated {
                showAlert(title: "Couldn't check for updates", message: "No release information was found. Try again later.", button: "OK")
            }
            return
        }

        let cleanRemoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let cleanCurrentVersion = UpdateManager.currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))

        let isNewer = Self.compare(cleanRemoteVersion, cleanCurrentVersion) > 0
        if isNewer || userInitiated { log("check: latest on GitHub is \(cleanRemoteVersion), newer: \(isNewer)") }

        setAvailableVersion(isNewer ? cleanRemoteVersion : nil)

        if !isNewer {
            if userInitiated {
                showAlert(
                    title: "Que is up to date",
                    message: "You have the newest version, \(cleanCurrentVersion).",
                    button: "OK"
                )
            }
            return
        }

        // Background checks only light the blue dot; the window opens when the user chooses Check for Updates.
        guard userInitiated else { return }

        // Newer version found!
        let body = (json["body"] as? String) ?? "A new version of Que is available."
        let htmlURL = (json["html_url"] as? String) ?? "https://github.com/\(UpdateManager.repoOwner)/\(UpdateManager.repoName)/releases"

        promptUserToUpdate(
            remoteVersion: cleanRemoteVersion,
            releaseNotes: body,
            downloadURL: Self.zipAssetURL(in: json),
            signatureURL: Self.assetURL(in: json) { $0 == UpdateSignature.assetName },
            fallbackWebURL: URL(string: htmlURL) ?? URL(string: "https://github.com/\(UpdateManager.repoOwner)/\(UpdateManager.repoName)/releases")!
        )
    }

    /// The release's Que.zip, only from github.com's release-download path (anything else: no in-app install).
    public static func zipAssetURL(in json: [String: Any]) -> URL? {
        assetURL(in: json) { $0.lowercased().hasSuffix(".zip") }
    }

    /// The first release asset whose name matches, only from this repo's github.com release-download path.
    public static func assetURL(in json: [String: Any], named matches: (String) -> Bool) -> URL? {
        let assets = json["assets"] as? [[String: Any]] ?? []
        return assets.compactMap { asset -> URL? in
            guard let name = asset["name"] as? String, matches(name),
                  let string = asset["browser_download_url"] as? String, let url = URL(string: string),
                  isTrustedDownloadURL(url) else { return nil }
            return url
        }.first
    }

    private func promptUserToUpdate(
        remoteVersion: String,
        releaseNotes: String,
        downloadURL: URL?,
        signatureURL: URL?,
        fallbackWebURL: URL
    ) {
        let alert = NSAlert()
        alert.messageText = "Que \(remoteVersion) is available"
        alert.informativeText = "You have version \(UpdateManager.currentVersion)."
        let items = Self.releaseNoteItems(releaseNotes)
        if !items.isEmpty { alert.accessoryView = Self.releaseNotesView(items) }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")

        let response = present(alert)
        log("prompt for \(remoteVersion): \(response == .alertFirstButtonReturn ? "Update Now" : "Later")")
        if response == .alertFirstButtonReturn {
            // 11: only a copy in /Applications updates in place; anywhere else (the DMG, Downloads) gets the release page.
            // A release without its seal (Que.zip.sig) opens the release page too: nothing unverified is installed.
            if let downloadURL = downloadURL, let signatureURL = signatureURL, Bundle.main.bundlePath.hasPrefix("/Applications/") {
                performDownloadAndInstall(from: downloadURL, signatureURL: signatureURL, remoteVersion: remoteVersion)
            } else {
                NSWorkspace.shared.open(fallbackWebURL)
            }
        }
        // "Later": nothing else happens; the blue dot stays until the update is installed.
    }

    /// The release notes as short items for the update window. Notes are written as "- " lines; markdown markers are
    /// stripped, and an old-style paragraph is split into one item per sentence. At most 8 items (the rest are summed up).
    public static func releaseNoteItems(_ body: String) -> [String] {
        func clean(_ line: String) -> String {
            var text = line.trimmingCharacters(in: .whitespaces)
            while let first = text.first, "-*•".contains(first) { text.removeFirst(); text = text.trimmingCharacters(in: .whitespaces) }
            return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        }
        var lines = body.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }   // headings
            .map(clean).filter { !$0.isEmpty }
        if lines.count == 1 {   // one long paragraph: one item per sentence
            // Split after . ! ? followed by a space (NSString's sentence splitter doesn't break before a symbol like ⌘).
            var sentences: [String] = []
            var current = ""
            let chars = Array(lines[0])
            for (n, ch) in chars.enumerated() {
                current.append(ch)
                if ".!?".contains(ch), n + 1 < chars.count, chars[n + 1] == " " {
                    sentences.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current.trimmingCharacters(in: .whitespaces)) }
            lines = sentences
        }
        guard lines.count > 8 else { return lines }
        return Array(lines.prefix(7)) + ["And a few smaller fixes."]
    }

    /// "What's new" with a hanging-indent bullet list, as the update window's accessory view.
    public static func releaseNotesView(_ items: [String], width: CGFloat = 300) -> NSView {
        let list = NSMutableParagraphStyle()
        list.headIndent = 14
        list.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
        list.paragraphSpacing = 5
        let heading = NSMutableParagraphStyle()
        heading.paragraphSpacing = 6
        let text = NSMutableAttributedString(string: "What's new\n", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: heading])
        for (index, item) in items.enumerated() {
            text.append(NSAttributedString(string: "•\t\(item)" + (index == items.count - 1 ? "" : "\n"), attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: list]))
        }
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.preferredMaxLayoutWidth = width
        label.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        label.frame.size.height = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 100)
        return label
    }

    /// AUDIT: release assets must be served over HTTPS from github.com's release-download path.
    /// Anything else falls back to opening the release page in the browser (no silent install).
    public static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else { return false }
        // This repo's releases only (any repo's /releases/download/ used to pass).
        return url.path.lowercased().hasPrefix("/\(repoOwner)/\(repoName)/releases/download/".lowercased())
    }

    public static func isTrustedFinalHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "github.com" || h.hasSuffix(".githubusercontent.com")
    }

    private func performDownloadAndInstall(from url: URL, signatureURL: URL, remoteVersion: String) {
        let alert = NSAlert()
        alert.messageText = "Getting Que \(remoteVersion)"
        alert.informativeText = "It downloads in the background. Que restarts by itself when it's ready."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        // The seal first (a few bytes), then the zip, which is installed only if the seal matches it.
        URLSession.shared.dataTask(with: signatureURL) { [weak self] sigData, sigResponse, _ in
            let signature = (sigResponse as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } == true
                && Self.isTrustedFinalHost(sigResponse?.url?.host) ? sigData.flatMap { String(data: $0, encoding: .utf8) } : nil
            guard let signature = signature else {
                // The release has a seal (checked before), so this is the connection: say so, and skip the 5 MB download.
                DispatchQueue.main.async { self?.downloadFailed("seal download failed", unverified: false) }
                return
            }
            self?.downloadZip(from: url, signature: signature)
        }.resume()

        // After the download has started: this window is modal, so showing it first held the download until OK was clicked.
        downloadAlertShowing = true
        present(alert)
        downloadAlertShowing = false
    }

    private func downloadZip(from url: URL, signature: String) {
        URLSession.shared.downloadTask(with: url) { [weak self] tempFileUrl, response, error in
            // AUDIT: URLSession deletes `tempFileUrl` the moment this closure returns. The original hopped to
            // the main queue first and used the file afterwards, which only works if the main thread happens
            // to win that race. Move the file to a stable location HERE, before hopping.
            var stagedURL: URL?
            var failure: String? = error?.localizedDescription

            if let tempFileUrl = tempFileUrl, error == nil {
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    failure = "The server returned HTTP \(http.statusCode)."
                } else if !Self.isTrustedFinalHost(response?.url?.host) {
                    failure = "The download was redirected to an unexpected host."
                } else {
                    let staged = FileManager.default.temporaryDirectory
                        .appendingPathComponent("QueUpdate_\(UUID().uuidString).zip")
                    do {
                        try FileManager.default.moveItem(at: tempFileUrl, to: staged)
                        if UpdateSignature.isSealed(fileAt: staged, signatureBase64: signature) {
                            stagedURL = staged
                        } else {
                            try? FileManager.default.removeItem(at: staged)
                            failure = Self.unverifiedFailure
                        }
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let stagedURL = stagedURL else {
                    self.downloadFailed(failure ?? "unknown error", unverified: failure == Self.unverifiedFailure)
                    return
                }
                if self.downloadAlertShowing { NSApp.abortModal() }   // done: the "downloading" window has served its purpose
                self.log("download ok")
                self.installZipUpdate(downloadedFile: stagedURL)
            }
        }.resume()
    }

    /// Main queue. Closes the "Getting Que…" window and says what went wrong (the reason goes to the update log).
    private func downloadFailed(_ reason: String, unverified: Bool) {
        if downloadAlertShowing { NSApp.abortModal() }
        log("download FAILED: \(reason)")
        showAlert(
            title: "Que couldn't update",
            message: unverified
                ? "This update couldn't be verified as coming from Que, so it wasn't installed. Try again later."
                : "The download didn't finish. Check your connection, then try again.",
            button: "OK"
        )
    }

    private static let unverifiedFailure = "signature missing or not matching Que's key"

    private var downloadAlertShowing = false

    private func installZipUpdate(downloadedFile: URL) {
        let fm = FileManager.default
        let tempExtractDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("QueUpdate_\(UUID().uuidString)")

        // AUDIT: extraction used to run on the main thread (waitUntilExit), freezing the pill and UI, and a
        // failed/partial `ditto` was never detected. Run it in the background and check the exit status.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-xk", downloadedFile.path, tempExtractDir.path]

            var problem: String?
            do {
                try ditto.run()
                ditto.waitUntilExit()
                if ditto.terminationStatus != 0 {
                    problem = "The update archive could not be extracted."
                }
            } catch {
                problem = "Failed to extract update: \(error.localizedDescription)"
            }

            // Que.zip holds Que.app. (2.0.0's zip also carried a CursorDeck.app copy for CursorDeck 1.x updaters;
            // accepting either name keeps any zip working.)
            let queURL = tempExtractDir.appendingPathComponent("Que.app")
            let appURL = fm.fileExists(atPath: queURL.path) ? queURL : tempExtractDir.appendingPathComponent("CursorDeck.app")
            if problem == nil {
                problem = self?.sanityCheckExtractedApp(appURL)
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.log(problem.map { "extract FAILED: \($0)" } ?? "extract ok")
                if let problem = problem {
                    try? fm.removeItem(at: tempExtractDir)   // AUDIT: failed updates used to leave these behind
                    try? fm.removeItem(at: downloadedFile)
                    self.showAlert(title: "Que couldn't update", message: problem, button: "OK")
                    return
                }
                self.swapInExtractedApp(appURL: appURL, tempExtractDir: tempExtractDir, downloadedFile: downloadedFile)
            }
        }
    }

    /// Returns a problem description, or nil if the extracted bundle looks like a genuine Que build.
    /// (Its bundle identifier is still com.cursordeck.app: CursorDeck 1.x updaters only accept that ID.)
    private func sanityCheckExtractedApp(_ appURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            return "The update archive did not contain the Que app."
        }
        guard let bundle = Bundle(url: appURL) else {
            return "The update archive did not contain a valid app bundle."
        }
        if let expectedID = Bundle.main.bundleIdentifier, bundle.bundleIdentifier != expectedID {
            return "The downloaded app does not match this application."
        }
        guard let exe = bundle.executableURL, FileManager.default.isExecutableFile(atPath: exe.path) else {
            return "The downloaded app is missing its executable."
        }
        return nil
    }

    private func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func swapInExtractedApp(appURL: URL, tempExtractDir: URL, downloadedFile: URL) {
        let fm = FileManager.default
        let destinationPath = Bundle.main.bundlePath   // only /Applications copies get here (promptUserToUpdate)
        let currentPID = ProcessInfo.processInfo.processIdentifier
        // The new copy's first launch is an update, not an install: no welcome tour (see WelcomeWindowController).
        UserDefaults.standard.set(true, forKey: WelcomeWindowController.updateInProgressKey)

        if !fm.isWritableFile(atPath: destinationPath) {
            // Root-owned bundle (e.g. installed by the old .pkg): needs an admin password once.
            // The admin step ONLY swaps the files (staged, so a failed copy leaves the old app) and gives the bundle
            // back to the user, so future updates are passwordless again. The relaunch then runs as the user, after
            // this process exits; it used to run `open` as root while the old app was still running.
            log("swap: app is not writable, asking for administrator permission")
            let dest = shellQuote(destinationPath), staged = shellQuote(destinationPath + ".que-new")
            let script = "rm -rf \(staged) && /usr/bin/ditto \(shellQuote(appURL.path)) \(staged) && rm -rf \(dest) && mv \(staged) \(dest) && /usr/sbin/chown -R \(shellQuote(NSUserName())):staff \(dest) && /usr/bin/xattr -cr \(dest)"
            let escaped = script
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let appleScriptSource = "do shell script \"\(escaped)\" with administrator privileges"
            var errorDict: NSDictionary?
            if let appleScript = NSAppleScript(source: appleScriptSource) {
                appleScript.executeAndReturnError(&errorDict)
                if errorDict == nil {
                    log("swap: admin copy ok, bundle now owned by the user")
                    let relaunch = "PID=\"$1\"; DEST=\"$2\"; LOG=\"$3\"\n"
                        + "log() { echo \"$(date '+%Y-%m-%dT%H:%M:%S') swap: $*\" >> \"$LOG\"; }\n"
                        + "i=0; while kill -0 \"$PID\" 2>/dev/null; do i=$((i + 1)); [ \"$i\" -gt 600 ] && exit 1; sleep 0.1; done\n"
                        + Self.relaunchShell
                    let relauncher = Process()
                    relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
                    relauncher.arguments = ["-c", relaunch, "sh", "\(currentPID)", destinationPath, Self.logURL.path]
                    try? relauncher.run()
                    try? fm.removeItem(at: tempExtractDir)
                    try? fm.removeItem(at: downloadedFile)
                    NSApplication.shared.terminate(nil)
                    return
                }
                log("swap: administrator permission not granted (\(errorDict?["NSAppleScriptErrorMessage"] ?? "cancelled"))")
            }
            // AUDIT: if the password prompt was cancelled the old code FELL THROUGH to the non-admin swap
            // below, which tries `rm -rf` on a root-owned bundle: it can delete part of the installed app and
            // then fail. Stop here and leave the installed app untouched.
            try? fm.removeItem(at: tempExtractDir)
            try? fm.removeItem(at: downloadedFile)
            showAlert(
                title: "Update not installed",
                message: "Que wasn't updated. It needs your administrator password. Try the update again.",
                button: "OK"
            )
            return
        }

        // Standard non-privileged swap, run by /bin/sh after this process exits.
        // AUDIT: paths are passed as positional arguments ($1..$5) instead of being interpolated into the
        // script text (no quoting/injection problems), and the swap is staged: the new app is copied next to
        // the old one first and the old one is only removed after the new one is in place, with rollback.
        // Previously `rm -rf` ran BEFORE `cp -R`, so a failed copy (disk full, etc.) left no app at all.
        let swapScript = """
        PID="$1"; NEW="$2"; DEST="$3"; TMP="$4"; ZIP="$5"; LOG="$6"
        log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') swap: $*" >> "$LOG"; }
        log "waiting for Que (pid $PID) to quit"
        i=0
        while kill -0 "$PID" 2>/dev/null; do
            i=$((i + 1))
            [ "$i" -gt 600 ] && exit 1
            sleep 0.1
        done
        log "quit; swapping in the new version"
        STAGE="$DEST.que-new"
        OLD="$DEST.que-old"
        rm -rf "$STAGE" "$OLD"
        if /usr/bin/ditto "$NEW" "$STAGE"; then
            if mv "$DEST" "$OLD"; then
                if mv "$STAGE" "$DEST"; then
                    rm -rf "$OLD"
                    log "swap ok"
                else
                    mv "$OLD" "$DEST"
                    rm -rf "$STAGE"
                    log "swap FAILED moving the new app in; old version restored"
                fi
            else
                rm -rf "$STAGE"
                log "swap FAILED moving the old app aside; old version kept"
            fi
        else
            rm -rf "$STAGE"
            log "swap FAILED copying the new app; old version kept"
        fi
        xattr -cr "$DEST" 2>/dev/null || true
        rm -rf "$TMP" "$ZIP"
        """ + "\n" + Self.relaunchShell

        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", swapScript, "sh", "\(currentPID)", appURL.path, destinationPath,
                                tempExtractDir.path, downloadedFile.path, Self.logURL.path]
        do {
            try relauncher.run()
            log("swap script started; quitting so it can replace the app")
            NSApplication.shared.terminate(nil)
        } catch {
            try? fm.removeItem(at: tempExtractDir)
            try? fm.removeItem(at: downloadedFile)
            showAlert(title: "Update couldn't be installed", message: "Failed to install update: \(error.localizedDescription)", button: "OK")
        }
    }

    // MARK: - Update log

    /// `~/Library/Logs/CursorDeck/update.log`: every step of an update, from the check to the relaunch, so a failed
    /// update can be diagnosed from the user's Mac (it couldn't be reproduced locally). Capped at ~200 KB.
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Que/update.log")

    func log(_ message: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: Self.logURL.path)[.size] as? Int), size > 200_000 {
            try? fm.removeItem(at: Self.logURL)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) app \(Self.currentVersion): \(message)\n"
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: Self.logURL, atomically: true, encoding: .utf8)
        }
    }

    /// Shell lines (sh) that log with `log`, then open "$DEST" and confirm CursorDeck is running again, retrying up
    /// to 3 times (macOS can briefly fail to open an app whose files were just swapped).
    private static let relaunchShell = """
    log "relaunching $DEST"
    attempt=1
    while [ "$attempt" -le 3 ]; do
        if out=$(/usr/bin/open "$DEST" 2>&1); then log "open #$attempt ok"; else log "open #$attempt failed: $out"; fi
        j=0
        while [ "$j" -lt 30 ]; do
            if /usr/bin/pgrep -f "$DEST/Contents/MacOS/" >/dev/null; then log "Que is running again"; exit 0; fi
            j=$((j + 1)); sleep 0.1
        done
        log "not running 3s after open #$attempt"
        attempt=$((attempt + 1))
    done
    log "GAVE UP relaunching: the user has to open Que manually"
    """

    private func showAlert(title: String, message: String, button: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: button)
        present(alert)
    }

    /// CursorDeck is a menu-bar-only app, so it is never the active app. Bring it forward first, otherwise the
    /// alert can open behind the window the user is working in.
    @discardableResult
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        return alert.runModal()
    }

    /// Compares two semver strings (e.g., "1.1.0" vs "1.0.0"). Returns >0 if v1 > v2, <0 if v1 < v2, 0 if equal.
    public static func compare(_ v1: String, _ v2: String) -> Int {
        // AUDIT: "1.2.0-beta" used to lose its last segment (compactMap dropped "0-beta"), comparing as 1.2.
        func parts(_ v: String) -> [Int] {
            let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? v
            return core.split(separator: ".").compactMap { Int($0) }
        }
        let p1 = parts(v1)
        let p2 = parts(v2)

        let count = max(p1.count, p2.count)
        for i in 0..<count {
            let num1 = i < p1.count ? p1[i] : 0
            let num2 = i < p2.count ? p2[i] : 0
            if num1 != num2 {
                return num1 > num2 ? 1 : -1
            }
        }
        return 0
    }
}

