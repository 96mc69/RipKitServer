@testable import RipKitServer
import Foundation
import VaporTesting
import Testing

@Suite("App Tests")
struct RipKitServerTests {
    @Test("yt-dlp arguments prefer compatible source streams")
    func ytDLPArgumentsPreferCompatibleSources() throws {
        let arguments = ytDLPArguments(
            sourceURL: "https://example.com/watch?v=1",
            outputTemplate: "/tmp/downloads/%(id)s.%(ext)s"
        )

        #expect(arguments.contains("--merge-output-format"))

        let mergeIndex = try #require(arguments.firstIndex(of: "--merge-output-format"))
        #expect(arguments[arguments.index(after: mergeIndex)] == "mp4")

        let sortIndex = try #require(arguments.firstIndex(of: "-S"))
        #expect(arguments[arguments.index(after: sortIndex)] == "vcodec:h264,acodec:aac,hdr:12,res:1080,fps:60")

        let printIndex = try #require(arguments.firstIndex(of: "--print"))
        #expect(arguments[arguments.index(after: printIndex)] == "after_move:filepath")
    }

    @Test("yt-dlp arguments include cookies file when configured")
    func ytDLPArgumentsIncludeCookiesFile() throws {
        let arguments = ytDLPArguments(
            sourceURL: "https://www.instagram.com/reel/example/",
            outputTemplate: "/tmp/downloads/%(id)s.%(ext)s",
            cookieConfiguration: YTDLPCookieConfiguration(
                cookiesFilePath: "/tmp/instagram-cookies.txt"
            )
        )

        let cookiesIndex = try #require(arguments.firstIndex(of: "--cookies"))
        #expect(arguments[arguments.index(after: cookiesIndex)] == "/tmp/instagram-cookies.txt")
    }

    @Test("yt-dlp arguments fall back to browser cookies when no file is set")
    func ytDLPArgumentsIncludeBrowserCookies() throws {
        let arguments = ytDLPArguments(
            sourceURL: "https://www.instagram.com/reel/example/",
            outputTemplate: "/tmp/downloads/%(id)s.%(ext)s",
            cookieConfiguration: YTDLPCookieConfiguration(
                cookiesFromBrowser: "safari"
            )
        )

        let cookiesIndex = try #require(arguments.firstIndex(of: "--cookies-from-browser"))
        #expect(arguments[arguments.index(after: cookiesIndex)] == "safari")
    }

    @Test("yt-dlp prefers explicit cookies file over browser cookies")
    func ytDLPArgumentsPreferCookiesFile() throws {
        let arguments = ytDLPArguments(
            sourceURL: "https://www.instagram.com/reel/example/",
            outputTemplate: "/tmp/downloads/%(id)s.%(ext)s",
            cookieConfiguration: YTDLPCookieConfiguration(
                cookiesFilePath: "/tmp/instagram-cookies.txt",
                cookiesFromBrowser: "safari"
            )
        )

        #expect(arguments.contains("--cookies"))
        #expect(!arguments.contains("--cookies-from-browser"))
    }

    @Test("ffmpeg arguments normalize video for Apple playback")
    func ffmpegArgumentsNormalizeForApplePlayback() throws {
        let arguments = ffmpegArguments(
            inputFilePath: "/tmp/downloads/input.webm",
            outputFilePath: "/tmp/downloads/input-ios.mp4"
        )

        #expect(arguments.contains("-nostdin"))
        #expect(arguments.contains("-hide_banner"))
        #expect(arguments.contains("-nostats"))

        let logLevelIndex = try #require(arguments.firstIndex(of: "-loglevel"))
        #expect(arguments[arguments.index(after: logLevelIndex)] == "error")

        let videoCodecIndex = try #require(arguments.firstIndex(of: "-c:v"))
        #expect(arguments[arguments.index(after: videoCodecIndex)] == "libx264")

        let filterIndex = try #require(arguments.firstIndex(of: "-vf"))
        #expect(arguments[arguments.index(after: filterIndex)] == "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p")

        let tagIndex = try #require(arguments.firstIndex(of: "-tag:v"))
        #expect(arguments[arguments.index(after: tagIndex)] == "avc1")

        let flagsIndex = try #require(arguments.firstIndex(of: "-movflags"))
        #expect(arguments[arguments.index(after: flagsIndex)] == "+faststart")

        let audioCodecIndex = try #require(arguments.firstIndex(of: "-c:a"))
        #expect(arguments[arguments.index(after: audioCodecIndex)] == "aac")
    }

    @Test("transcoded files get an iOS-safe mp4 name")
    func transcodedFileURLUsesIOSSuffix() {
        let fileURL = URL(fileURLWithPath: "/tmp/downloads/sample.webm")
        let transcodedURL = transcodedFileURL(for: fileURL)

        #expect(transcodedURL.lastPathComponent == "sample-ios.mp4")
    }

    @Test("POST /api/download queues a background job")
    func downloadRouteQueuesBackgroundJob() async throws {
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
            app.mediaDownloadJobStore = MediaDownloadJobStore()
            app.mediaDownloadService = MediaDownloadService { _, outputDirectory in
                try await Task.sleep(for: .milliseconds(25))
                let fileURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
                    .appendingPathComponent("sample-ios.mp4")
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
                #expect(payload.status == .queued)
                #expect(payload.statusPath == "/api/download/\(payload.jobID)")
                #expect(payload.fileName == nil)
                #expect(payload.downloadPath == nil)
                #expect(payload.error == nil)
            })
        }
    }

    @Test("GET /api/download/:jobID returns the job status")
    func downloadStatusRouteReturnsJobStatus() async throws {
        try await withApp(configure: configure) { app in
            let jobStore = MediaDownloadJobStore()
            app.mediaDownloadJobStore = jobStore

            let queuedJob = await jobStore.createQueuedJob()
            await jobStore.markCompleted(
                jobID: queuedJob.jobID,
                media: DownloadedMedia(
                    fileName: "sample-ios.mp4",
                    filePath: "/tmp/sample-ios.mp4"
                )
            )

            try await app.testing().test(.GET, "api/download/\(queuedJob.jobID)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(DownloadResponse.self)
                #expect(payload.jobID == queuedJob.jobID)
                #expect(payload.status == .completed)
                #expect(payload.fileName == "sample-ios.mp4")
                #expect(payload.downloadPath == "/downloads/sample-ios.mp4")
                #expect(payload.error == nil)
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

            let fileURL = downloadDirectory.appendingPathComponent("sample.mp4")
            try Data("fixture-data".utf8).write(to: fileURL)
            app.mediaDownloadDirectory = downloadDirectory.path

            try await app.testing().test(.GET, "downloads/sample.mp4", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentDisposition) == "attachment; filename=\"sample.mp4\"")
                #expect(res.headers.first(name: .contentType) == "video/mp4")
                #expect(res.body.string == "fixture-data")
            })
        }
    }
}
