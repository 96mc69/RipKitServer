@testable import RipKitServer
import Foundation
import VaporTesting
import Testing

@Suite("App Tests")
struct RipKitServerTests {
    @Test("yt-dlp arguments force an mp4 output")
    func ytDLPArgumentsForceMP4Output() throws {
        let arguments = ytDLPArguments(
            sourceURL: "https://example.com/watch?v=1",
            outputTemplate: "/tmp/downloads/%(id)s.%(ext)s"
        )

        #expect(arguments.contains("--merge-output-format"))
        #expect(arguments.contains("--recode-video"))

        let mergeIndex = try #require(arguments.firstIndex(of: "--merge-output-format"))
        #expect(arguments[arguments.index(after: mergeIndex)] == "mp4")

        let recodeIndex = try #require(arguments.firstIndex(of: "--recode-video"))
        #expect(arguments[arguments.index(after: recodeIndex)] == "mp4")

        let sortIndex = try #require(arguments.firstIndex(of: "-S"))
        #expect(arguments[arguments.index(after: sortIndex)] == "vcodec:h264,acodec:aac,hdr:12,res:1080,fps:60")

        let postProcessorIndex = try #require(arguments.firstIndex(of: "--postprocessor-args"))
        let postProcessorArgs = arguments[arguments.index(after: postProcessorIndex)]
        #expect(postProcessorArgs.contains("libx264"))
        #expect(postProcessorArgs.contains("-tag:v avc1"))
        #expect(postProcessorArgs.contains("-pix_fmt yuv420p"))
        #expect(postProcessorArgs.contains("-movflags +faststart"))

        let printIndex = try #require(arguments.firstIndex(of: "--print"))
        #expect(arguments[arguments.index(after: printIndex)] == "after_move:filepath")
    }

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
                    .appendingPathComponent("sample.mp4")
                try Data("video".utf8).write(to: fileURL)

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
                #expect(payload.fileName == "sample.mp4")
                #expect(payload.downloadPath == "/downloads/sample.mp4")
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
