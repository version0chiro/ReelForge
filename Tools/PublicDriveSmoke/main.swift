import Foundation

@main
struct PublicDriveSmoke {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: public-drive-smoke <public-folder-url>\n", stderr)
            exit(64)
        }

        do {
            let folder = try await PublicGoogleDriveClient().discoverFolder(
                from: CommandLine.arguments[1]
            )
            print("reachable \(folder.name) \(folder.videos.count) supported videos")
        } catch PublicDriveError.noVideos {
            print("reachable; no supported videos in this test folder")
        } catch {
            fputs("public Drive smoke failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
