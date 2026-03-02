import Foundation
import Vapor

struct DownloadRequest: Content {
    let url: String
}

struct DownloadResponse: Content {
    let fileName: String
    let downloadPath: String
}

struct DownloadedMedia: Sendable {
    let fileName: String
    let filePath: String
}

struct MediaDownloadService: Sendable {
    let download: @Sendable (_ sourceURL: String, _ outputDirectory: String) async throws -> DownloadedMedia
}

extension MediaDownloadService {
    static let live = MediaDownloadService { sourceURL, outputDirectory in
        guard let remoteURL = URL(string: sourceURL),
              let scheme = remoteURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw Abort(.badRequest, reason: "A valid http(s) URL is required.")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            atPath: outputDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let outputTemplate = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).%(ext)s")
            .path

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ytDLPArguments(
                sourceURL: sourceURL,
                outputTemplate: outputTemplate
            )
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(decoding: stdoutData, as: UTF8.self)
                let stderr = String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard process.terminationStatus == 0 else {
                    let reason = stderr.isEmpty
                        ? "yt-dlp failed with exit code \(process.terminationStatus)."
                        : "yt-dlp failed: \(stderr)"
                    continuation.resume(throwing: Abort(.badGateway, reason: reason))
                    return
                }

                guard let downloadedPath = stdout
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .last,
                    !downloadedPath.isEmpty else {
                    continuation.resume(
                        throwing: Abort(
                            .internalServerError,
                            reason: "yt-dlp did not report a downloaded file path."
                        )
                    )
                    return
                }

                let fileURL = URL(fileURLWithPath: downloadedPath)
                continuation.resume(
                    returning: DownloadedMedia(
                        fileName: fileURL.lastPathComponent,
                        filePath: fileURL.path
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(
                    throwing: Abort(
                        .internalServerError,
                        reason: "Failed to start yt-dlp: \(error.localizedDescription)"
                    )
                )
            }
        }
    }
}

func ytDLPArguments(sourceURL: String, outputTemplate: String) -> [String] {
    [
        "yt-dlp",
        "--no-playlist",
        "--no-progress",
        "--restrict-filenames",
        "--format",
        "bv*+ba/b",
        "-S",
        "vcodec:h264,acodec:aac,hdr:12,res:1080,fps:60",
        "--merge-output-format",
        "mp4",
        "--recode-video",
        "mp4",
        "--postprocessor-args",
        "VideoConvertor+FFmpeg_o:-c:v libx264 -tag:v avc1 -pix_fmt yuv420p -profile:v high -level 4.1 -movflags +faststart -c:a aac -b:a 192k -ar 48000",
        "--print",
        "after_move:filepath",
        "--output",
        outputTemplate,
        sourceURL,
    ]
}

private struct MediaDownloadServiceKey: StorageKey {
    typealias Value = MediaDownloadService
}

private struct MediaDownloadDirectoryKey: StorageKey {
    typealias Value = String
}

extension Application {
    var mediaDownloadService: MediaDownloadService {
        get { self.storage[MediaDownloadServiceKey.self] ?? .live }
        set { self.storage[MediaDownloadServiceKey.self] = newValue }
    }

    var mediaDownloadDirectory: String {
        get { self.storage[MediaDownloadDirectoryKey.self] ?? (self.directory.workingDirectory + "Storage/Downloads") }
        set { self.storage[MediaDownloadDirectoryKey.self] = newValue }
    }
}
