import Foundation

struct PublicDriveVideo: Equatable {
    let id: String
    let name: String
    let relativePath: String
}

struct PublicDriveFolder: Equatable {
    let id: String
    let name: String
    let videos: [PublicDriveVideo]
}

enum PublicDriveError: LocalizedError {
    case invalidFolderURL
    case folderUnavailable
    case malformedFolder
    case noVideos
    case tooManyVideos(Int)
    case downloadUnavailable(String)
    case httpFailure(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFolderURL:
            "Paste a Google Drive folder URL such as https://drive.google.com/drive/folders/…"
        case .folderUnavailable:
            "The Drive folder could not be opened. Set General access to “Anyone with the link” and try again."
        case .malformedFolder:
            "Google returned a folder page ReelForge could not read. The public Drive page format may have changed."
        case .noVideos:
            "No public MP4, MOV, or M4V videos were found in that folder or its subfolders."
        case let .tooManyVideos(limit):
            "The folder contains more than \(limit) videos. Use a smaller public folder for one montage."
        case let .downloadUnavailable(name):
            "Google Drive would not provide a public download for \(name). Check its sharing permission or download quota."
        case let .httpFailure(status):
            "Google Drive returned HTTP \(status). Try again later or verify the folder is public."
        }
    }
}

final class PublicGoogleDriveClient {
    private struct FolderEntry: Equatable {
        enum Kind: Equatable {
            case file
            case folder
        }

        let id: String
        let name: String
        let kind: Kind
    }

    private let session: URLSession
    private let maximumVideos = 200
    private let maximumDepth = 8
    private let folderUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36"

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage()
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        session = URLSession(configuration: configuration)
    }

    static func folderID(from text: String) throws -> String {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(),
              host == "drive.google.com" || host == "docs.google.com" else {
            throw PublicDriveError.invalidFolderURL
        }

        let path = components.path.split(separator: "/").map(String.init)
        guard let marker = path.firstIndex(of: "folders"),
              path.indices.contains(marker + 1) else {
            throw PublicDriveError.invalidFolderURL
        }

        let folderID = path[marker + 1]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard folderID.count >= 10,
              folderID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw PublicDriveError.invalidFolderURL
        }
        return folderID
    }

    func discoverFolder(
        from urlText: String,
        progress: ((Double, String) -> Void)? = nil
    ) async throws -> PublicDriveFolder {
        let rootID = try Self.folderID(from: urlText)
        var visitedFolders: Set<String> = []
        var visitedFiles: Set<String> = []
        var videos: [PublicDriveVideo] = []
        var rootName = "Google Drive Montage"

        try await discover(
            folderID: rootID,
            path: [],
            depth: 0,
            visitedFolders: &visitedFolders,
            visitedFiles: &visitedFiles,
            videos: &videos,
            rootName: &rootName,
            progress: progress
        )

        guard !videos.isEmpty else { throw PublicDriveError.noVideos }
        return PublicDriveFolder(
            id: rootID,
            name: Self.sanitizePathComponent(rootName),
            videos: videos
        )
    }

    func downloadVideos(
        _ videos: [PublicDriveVideo],
        to directory: URL,
        progress: ((Double, String) -> Void)? = nil
    ) async throws -> [URL] {
        var downloaded: [URL] = []
        for (index, video) in videos.enumerated() {
            try Task.checkCancellation()
            progress?(Double(index) / Double(max(1, videos.count)), video.name)

            let relativeComponents = video.relativePath
                .split(separator: "/")
                .map { Self.sanitizePathComponent(String($0)) }
            let destination = relativeComponents.reduce(directory) {
                $0.appendingPathComponent($1)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await download(video: video, to: destination)
            downloaded.append(destination)
            progress?(Double(index + 1) / Double(max(1, videos.count)), video.name)
        }
        return downloaded
    }

    static func parseFolderHTML(
        _ html: String,
        folderID: String
    ) throws -> (name: String, entries: [(id: String, name: String, isFolder: Bool)]) {
        guard let rawTitle = firstCapture(
            pattern: #"<title[^>]*>(.*?)</title>"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            throw PublicDriveError.malformedFolder
        }

        let folderName = normalizeVisibleText(rawTitle)
        guard !folderName.isEmpty else { throw PublicDriveError.malformedFolder }

        let anchorPattern = #"<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        let captures = allCaptures(
            pattern: anchorPattern,
            in: html,
            captureCount: 2,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        var entries: [(id: String, name: String, isFolder: Bool)] = []
        var seen: Set<String> = []

        for capture in captures {
            let href = decodeHTMLEntities(capture[0])
            let name = normalizeVisibleText(capture[1])
            guard !name.isEmpty else { continue }

            if let fileID = firstCapture(
                pattern: #"https://drive\.google\.com/file/d/([A-Za-z0-9_-]{10,})/(?:view|preview)"#,
                in: href,
                options: [.caseInsensitive]
            ), seen.insert("file:\(fileID)").inserted {
                entries.append((fileID, name, false))
                continue
            }

            if let childID = try? Self.folderID(from: href),
               childID != folderID,
               seen.insert("folder:\(childID)").inserted {
                entries.append((childID, name, true))
            }
        }
        return (folderName, entries)
    }

    static func confirmationURL(from html: String, baseURL: URL) -> URL? {
        if let href = firstCapture(
            pattern: #"href=["'](/uc\?export=download[^"']+)["']"#,
            in: html,
            options: [.caseInsensitive]
        ) {
            return URL(string: decodeHTMLEntities(href), relativeTo: baseURL)?.absoluteURL
        }

        let forms = allCaptures(
            pattern: #"(<form\b[^>]*>)(.*?)</form>"#,
            in: html,
            captureCount: 2,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        for form in forms {
            let openingTag = form[0]
            guard attribute("id", in: openingTag) == "download-form",
                  let action = attribute("action", in: openingTag),
                  let actionURL = URL(string: decodeHTMLEntities(action), relativeTo: baseURL)?.absoluteURL,
                  var components = URLComponents(url: actionURL, resolvingAgainstBaseURL: true) else {
                continue
            }

            var queryItems = components.queryItems ?? []
            let inputs = allCaptures(
                pattern: #"(<input\b[^>]*>)"#,
                in: form[1],
                captureCount: 1,
                options: [.caseInsensitive]
            )
            for input in inputs {
                guard attribute("type", in: input[0])?.lowercased() == "hidden",
                      let name = attribute("name", in: input[0]),
                      let value = attribute("value", in: input[0]) else {
                    continue
                }
                queryItems.removeAll { $0.name == name }
                queryItems.append(URLQueryItem(name: name, value: decodeHTMLEntities(value)))
            }
            components.queryItems = queryItems
            if let url = components.url {
                return url
            }
        }

        if let escaped = firstCapture(
            pattern: #""downloadUrl":"([^"]+)""#,
            in: html
        ) {
            let decoded = escaped
                .replacingOccurrences(of: #"\/"#, with: "/")
                .replacingOccurrences(of: #"\u003d"#, with: "=")
                .replacingOccurrences(of: #"\u0026"#, with: "&")
            return URL(string: decoded)
        }
        return nil
    }

    private func discover(
        folderID: String,
        path: [String],
        depth: Int,
        visitedFolders: inout Set<String>,
        visitedFiles: inout Set<String>,
        videos: inout [PublicDriveVideo],
        rootName: inout String,
        progress: ((Double, String) -> Void)?
    ) async throws {
        guard depth <= maximumDepth, visitedFolders.insert(folderID).inserted else { return }
        try Task.checkCancellation()

        var components = URLComponents(string: "https://drive.google.com/embeddedfolderview")!
        components.queryItems = [URLQueryItem(name: "id", value: folderID)]
        var request = URLRequest(url: components.url!)
        request.setValue(folderUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PublicDriveError.folderUnavailable
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 404 {
                throw PublicDriveError.folderUnavailable
            }
            throw PublicDriveError.httpFailure(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw PublicDriveError.malformedFolder
        }

        let parsed = try Self.parseFolderHTML(html, folderID: folderID)
        if depth == 0 {
            rootName = parsed.name
        }
        progress?(
            min(0.95, Double(visitedFolders.count) / 20),
            path.isEmpty ? parsed.name : path.joined(separator: " / ")
        )

        for entry in parsed.entries {
            try Task.checkCancellation()
            if entry.isFolder {
                try await discover(
                    folderID: entry.id,
                    path: path + [Self.sanitizePathComponent(entry.name)],
                    depth: depth + 1,
                    visitedFolders: &visitedFolders,
                    visitedFiles: &visitedFiles,
                    videos: &videos,
                    rootName: &rootName,
                    progress: progress
                )
                continue
            }

            guard Self.isSupportedVideo(entry.name),
                  visitedFiles.insert(entry.id).inserted else {
                continue
            }
            if videos.count >= maximumVideos {
                throw PublicDriveError.tooManyVideos(maximumVideos)
            }
            let safeName = Self.sanitizePathComponent(entry.name)
            videos.append(
                PublicDriveVideo(
                    id: entry.id,
                    name: safeName,
                    relativePath: (path + [safeName]).joined(separator: "/")
                )
            )
        }
    }

    private func download(video: PublicDriveVideo, to destination: URL) async throws {
        var components = URLComponents(string: "https://drive.google.com/uc")!
        components.queryItems = [
            URLQueryItem(name: "export", value: "download"),
            URLQueryItem(name: "id", value: video.id),
        ]
        var nextURL = components.url!

        for _ in 0..<4 {
            try Task.checkCancellation()
            var request = URLRequest(url: nextURL)
            request.setValue(folderUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (temporaryURL, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PublicDriveError.downloadUnavailable(video.name)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw PublicDriveError.httpFailure(http.statusCode)
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let hasAttachment = http.value(forHTTPHeaderField: "Content-Disposition") != nil
            if hasAttachment || !contentType.contains("text/html") {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                return
            }

            let data = try Data(contentsOf: temporaryURL)
            guard let html = String(data: data, encoding: .utf8),
                  let confirmation = Self.confirmationURL(
                    from: html,
                    baseURL: http.url ?? nextURL
                  ) else {
                throw PublicDriveError.downloadUnavailable(video.name)
            }
            nextURL = confirmation
        }
        throw PublicDriveError.downloadUnavailable(video.name)
    }

    private static func isSupportedVideo(_ name: String) -> Bool {
        ["mp4", "mov", "m4v"].contains(
            URL(fileURLWithPath: name).pathExtension.lowercased()
        )
    }

    private static func sanitizePathComponent(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Untitled" : cleaned
    }

    private static func normalizeVisibleText(_ html: String) -> String {
        let withoutTags = replacing(
            pattern: #"<[^>]+>"#,
            in: html,
            with: " ",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        return decodeHTMLEntities(withoutTags)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var decoded = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")

        let expression = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#)
        let matches = expression?.matches(
            in: decoded,
            range: NSRange(decoded.startIndex..., in: decoded)
        ) ?? []
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range(at: 0), in: decoded),
                  let numberRange = Range(match.range(at: 1), in: decoded) else {
                continue
            }
            let raw = String(decoded[numberRange])
            let radix = raw.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(raw.dropFirst()) : raw
            guard let scalarValue = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(scalarValue) else {
                continue
            }
            decoded.replaceSubrange(wholeRange, with: String(Character(scalar)))
        }
        return decoded
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        firstCapture(
            pattern: #"\b\#(name)\s*=\s*["']([^"']*)["']"#,
            in: tag,
            options: [.caseInsensitive]
        ).map(decodeHTMLEntities)
    }

    private static func firstCapture(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func allCaptures(
        pattern: String,
        in text: String,
        captureCount: Int,
        options: NSRegularExpression.Options = []
    ) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            guard match.numberOfRanges > captureCount else { return nil }
            var captures: [String] = []
            for index in 1...captureCount {
                guard let range = Range(match.range(at: index), in: text) else {
                    return nil
                }
                captures.append(String(text[range]))
            }
            return captures
        }
    }

    private static func replacing(
        pattern: String,
        in text: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }
}
