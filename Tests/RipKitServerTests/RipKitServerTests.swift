@testable import RipKitServer
import Foundation
import VaporTesting
import Testing

@Suite("App Tests")
struct RipKitServerTests {
    @Test("POST /api/download returns a download URL")
    func downloadRouteReturnsDownloadURL() async throws {
        try await withApp(configure: configure) { app in
            let downloadDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: downloadDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            defer { try? FileManager.default.removeItem(at: downloadDirectory) }

            app.mediaDownloadDirectory = downloadDirectory.path
            app.mediaDownloadService = MediaDownloadService { _, outputDirectory in
                let fileURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
                    .appendingPathComponent("sample.mp3")
                try Data("audio".utf8).write(to: fileURL)

                return DownloadedMedia(
                    fileName: fileURL.lastPathComponent,
                    filePath: fileURL.path
                )
            }

            try await app.testing().test(.POST, "api/download", beforeRequest: { req in
                try req.content.encode(DownloadRequest(url: "https://example.com/watch?v=1"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(DownloadResponse.self)
                #expect(payload.fileName == "sample.mp3")
                #expect(payload.downloadPath == "/downloads/sample.mp3")
            })
        }
    }

    @Test("GET /downloads/:filename streams the saved file")
    func downloadsRouteStreamsSavedFile() async throws {
        try await withApp(configure: configure) { app in
            let downloadDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: downloadDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            defer { try? FileManager.default.removeItem(at: downloadDirectory) }

            let fileURL = downloadDirectory.appendingPathComponent("sample.txt")
            try Data("fixture-data".utf8).write(to: fileURL)
            app.mediaDownloadDirectory = downloadDirectory.path

            try await app.testing().test(.GET, "downloads/sample.txt", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentDisposition) == "attachment; filename=\"sample.txt\"")
                #expect(res.body.string == "fixture-data")
            })
        }
    }
}
