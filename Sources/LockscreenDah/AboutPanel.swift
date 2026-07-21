import AppKit
import CryptoKit

/// "About Lockscreen Dah?" popup: intro, author, version, and update actions
/// backed by the GitHub releases API — Download Update (fetch + verify the
/// release build into Downloads) and Check Releases (open the page).
final class AboutPanel: NSObject {
    static let shared = AboutPanel()

    /// The macOS app's own repo (Windows lives at jvloo/lockscreen-dah-windows).
    /// Not created yet — the update check reports "no releases" gracefully
    /// until the first tag exists. Update if it moves.
    private static let repoPath = "jvloo/lockscreen-dah-macos"
    private static let releasesPageURL = URL(string: "https://github.com/\(repoPath)/releases")!
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repoPath)/releases/latest")!
    private static let readMoreURL = URL(string: "https://github.com/\(repoPath)#readme")!

    private var panel: NSPanel?
    private var statusLabel: NSTextField?
    private var downloadButton: NSButton?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    func show() {
        if let panel {
            panel.present()
            return
        }

        let panel = NSPanel.floating(
            title: "About Lockscreen Dah?",
            contentSize: NSSize(width: 420, height: 360)
        )
        panel.center()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "faceid",
            accessibilityDescription: "Lockscreen Dah?"
        )?.withSymbolConfiguration(.init(pointSize: 42, weight: .regular))
        icon.contentTintColor = .labelColor

        let name = NSTextField(labelWithString: "Lockscreen Dah?")
        name.font = .systemFont(ofSize: 24, weight: .bold)

        let version = NSTextField(labelWithString: "Version \(Self.currentVersion)")
        version.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        version.textColor = .secondaryLabelColor

        let intro = NSTextField(wrappingLabelWithString:
            "Watches for your face and locks your screen the moment you step " +
            "away. All recognition runs on-device; no image ever leaves your computer."
        )
        intro.font = .systemFont(ofSize: 13)
        intro.textColor = .secondaryLabelColor
        intro.alignment = .center
        intro.preferredMaxLayoutWidth = 360

        // Second paragraph: same size/color as the description, with a "Read
        // more" link styled to match (only an underline marks it clickable).
        let purpose = NSTextField(wrappingLabelWithString: "")
        let purposeFont = NSFont.systemFont(ofSize: 13)
        let purposeText = NSMutableAttributedString(
            string: "Built to make workplace security a habit — never leave your "
                + "screen on and unattended. ",
            attributes: [
                .font: purposeFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        purposeText.append(NSAttributedString(
            string: "Read more",
            attributes: [
                .font: purposeFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: Self.readMoreURL,
            ]
        ))
        purpose.attributedStringValue = purposeText
        purpose.isSelectable = true
        purpose.allowsEditingTextAttributes = true
        purpose.alignment = .center
        purpose.preferredMaxLayoutWidth = 360

        // "Xavier Loo" links to the GitHub profile; a label renders a `.link`
        // attribute as a clickable link once it's selectable.
        let author = NSTextField(labelWithString: "")
        let authorText = NSMutableAttributedString(
            string: "Built by ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
        authorText.append(NSAttributedString(
            string: "Xavier Loo",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .link: URL(string: "https://github.com/jvloo")!,
            ]
        ))
        author.attributedStringValue = authorText
        author.isSelectable = true
        author.allowsEditingTextAttributes = true

        let releases = NSButton.rounded("Check Releases", target: self, action: #selector(openReleases))
        let download = NSButton.rounded("Download Update", target: self, action: #selector(downloadUpdate), isDefault: true)
        downloadButton = download

        let buttons = NSStackView(views: [releases, download])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        statusLabel = status

        let stack = NSStackView(views: [icon, name, version, intro, purpose, author, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(2, after: name)
        stack.setCustomSpacing(16, after: version)
        stack.setCustomSpacing(16, after: purpose)
        stack.setCustomSpacing(16, after: author)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        panel.contentView = content
        panel.present()
        self.panel = panel
    }

    // MARK: - Update: check → download → reveal

    /// One click: check the latest release; if it's newer and ships a build,
    /// download it to ~/Downloads (verifying the GitHub-provided SHA-256 when
    /// present) and reveal it in Finder for a manual drag-to-Applications.
    /// Deliberately manual — an ad-hoc-signed app can't safely self-replace.
    @objc private func downloadUpdate() {
        downloadButton?.isEnabled = false
        setStatus("Checking…")

        let task = URLSession.shared.dataTask(with: Self.latestReleaseAPI) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleReleaseInfo(data: data, response: response, error: error)
            }
        }
        task.resume()
    }

    private func handleReleaseInfo(data: Data?, response: URLResponse?, error: Error?) {
        func stop(_ message: String) {
            setStatus(message)
            downloadButton?.isEnabled = true
        }

        if let error { return stop("Couldn't check: \(error.localizedDescription)") }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return stop("No releases published yet — you're on v\(Self.currentVersion).")
        }
        guard
            let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String
        else {
            return stop("Couldn't read the release info from GitHub.")
        }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isVersion(latest, newerThan: Self.currentVersion) else {
            return stop("You're up to date — v\(Self.currentVersion) is the latest.")
        }

        // Newer version exists — find a downloadable .zip build.
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard
            let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
            let urlString = asset["browser_download_url"] as? String,
            let assetURL = URL(string: urlString)
        else {
            return stop("v\(latest) is available, but has no downloadable build — tap Check Releases.")
        }

        let name = asset["name"] as? String ?? "LockscreenDah-\(latest).zip"
        let digest = asset["digest"] as? String // "sha256:…" when GitHub provides it
        setStatus("Downloading v\(latest)…")
        let task = URLSession.shared.downloadTask(with: assetURL) { [weak self] tempURL, _, error in
            let outcome = Self.finishDownload(tempURL: tempURL, error: error, name: name, expectedDigest: digest)
            DispatchQueue.main.async {
                self?.downloadButton?.isEnabled = true
                switch outcome {
                case .success(let dest):
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                    self?.setStatus("Downloaded v\(latest) to Downloads — drag it into Applications to update.")
                case .failure(let message):
                    self?.setStatus(message)
                }
            }
        }
        task.resume()
    }

    private enum DownloadOutcome { case success(URL); case failure(String) }

    /// Runs on the download completion queue: verify the checksum (when the
    /// release advertises one) and move the file into ~/Downloads.
    private static func finishDownload(
        tempURL: URL?,
        error: Error?,
        name: String,
        expectedDigest: String?
    ) -> DownloadOutcome {
        if let error { return .failure("Download failed: \(error.localizedDescription)") }
        guard let tempURL, let data = try? Data(contentsOf: tempURL) else {
            return .failure("Download failed — no data received.")
        }
        if let expectedDigest, expectedDigest.hasPrefix("sha256:") {
            let want = expectedDigest.dropFirst("sha256:".count).lowercased()
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard got == want else {
                return .failure("Checksum mismatch — download rejected. Use Check Releases instead.")
            }
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let dest = downloads.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try data.write(to: dest)
            return .success(dest)
        } catch {
            return .failure("Couldn't save to Downloads: \(error.localizedDescription)")
        }
    }

    @objc private func openReleases() {
        NSWorkspace.shared.open(Self.releasesPageURL)
    }

    private func setStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
        let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(aParts.count, bParts.count) {
            let x = index < aParts.count ? aParts[index] : 0
            let y = index < bParts.count ? bParts[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
