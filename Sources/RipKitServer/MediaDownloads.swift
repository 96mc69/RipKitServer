import Foundation
import Vapor

struct DownloadRequest: Content {
    let url: String
}

struct DownloadResponse: Content {
    let jobID: String
    let status: DownloadStatus
    let statusPath: String
    let fileName: String?
    let downloadPath: String?
    let error: String?
}

enum DownloadStatus: String, Content, Sendable {
    case queued
    case processing
    case completed
    case failed
}

struct DownloadedMedia: Sendable {
    let fileName: String
    let filePath: String
}

struct YTDLPCookieConfiguration: Sendable, Equatable {
    let cookiesFilePath: String?
    let cookiesFromBrowser: String?

    init(cookiesFilePath: String? = nil, cookiesFromBrowser: String? = nil) {
        self.cookiesFilePath = cookiesFilePath?.trimmedToNil
        self.cookiesFromBrowser = cookiesFromBrowser?.trimmedToNil
    }

    static let disabled = YTDLPCookieConfiguration()

    var ytDLPArguments: [String] {
        if let cookiesFilePath {
            return ["--cookies", cookiesFilePath]
        }

        if let cookiesFromBrowser {
            return ["--cookies-from-browser", cookiesFromBrowser]
        }

        return []
    }
}

struct MediaDownloadService: Sendable {
    let download: @Sendable (_ sourceURL: String, _ outputDirectory: String) async throws -> DownloadedMedia
}

actor MediaDownloadJobStore {
    private var jobs: [String: DownloadResponse] = [:]

    func createQueuedJob() -> DownloadResponse {
        let jobID = UUID().uuidString
        let response = DownloadResponse(
            jobID: jobID,
            status: .queued,
            statusPath: "/api/download/\(jobID)",
            fileName: nil,
            downloadPath: nil,
            error: nil
        )
        jobs[jobID] = response
        return response
    }

    func markProcessing(jobID: String) {
        guard let job = jobs[jobID] else { return }
        jobs[jobID] = DownloadResponse(
            jobID: job.jobID,
            status: .processing,
            statusPath: job.statusPath,
            fileName: nil,
            downloadPath: nil,
            error: nil
        )
    }

    func markCompleted(jobID: String, media: DownloadedMedia) {
        guard let job = jobs[jobID] else { return }
        jobs[jobID] = DownloadResponse(
            jobID: job.jobID,
            status: .completed,
            statusPath: job.statusPath,
            fileName: media.fileName,
            downloadPath: "/downloads/\(media.fileName)",
            error: nil
        )
    }

    func markFailed(jobID: String, error: String) {
        guard let job = jobs[jobID] else { return }
        jobs[jobID] = DownloadResponse(
            jobID: job.jobID,
            status: .failed,
            statusPath: job.statusPath,
            fileName: nil,
            downloadPath: nil,
            error: error,
        )
    }

    func job(jobID: String) -> DownloadResponse? {
        jobs[jobID]
    }
}

private struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
}

extension MediaDownloadService {
    static func live(
        cookieConfiguration: YTDLPCookieConfiguration = .disabled
    ) -> MediaDownloadService {
        MediaDownloadService { sourceURL, outputDirectory in
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

            let ytDLPResult = try await runCommand(
                arguments: ytDLPArguments(
                    sourceURL: sourceURL,
                    outputTemplate: outputTemplate,
                    cookieConfiguration: cookieConfiguration
                ),
                commandName: "yt-dlp"
            )

            guard let downloadedPath = ytDLPResult.stdout
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last,
                !downloadedPath.isEmpty else {
                throw Abort(
                    .internalServerError,
                    reason: "yt-dlp did not report a downloaded file path."
                )
            }

            let downloadedFileURL = URL(fileURLWithPath: downloadedPath)
            let normalizedFileURL = transcodedFileURL(for: downloadedFileURL)

            do {
                _ = try await runCommand(
                    arguments: ffmpegArguments(
                        inputFilePath: downloadedFileURL.path,
                        outputFilePath: normalizedFileURL.path
                    ),
                    commandName: "ffmpeg"
                )
            } catch {
                try? fileManager.removeItem(at: normalizedFileURL)
                throw error
            }

            try? fileManager.removeItem(at: downloadedFileURL)

            return DownloadedMedia(
                fileName: normalizedFileURL.lastPathComponent,
                filePath: normalizedFileURL.path
            )
        }
    }
}

func ytDLPArguments(
    sourceURL: String,
    outputTemplate: String,
    cookieConfiguration: YTDLPCookieConfiguration = .disabled
) -> [String] {
    [
        "yt-dlp",
        "--no-playlist", /* if video is part of a playlist, just download this one video */
        "--no-progress", /* no interactive progress bars or anything, keep logs and stdout clean */
        "--restrict-filenames", /* restricted charset for filenames. helps avoid filesystem issues
                                 across platforms */
    ] + cookieConfiguration.ytDLPArguments + [
        "--format", /* selects "best video (any codec/quality) plus best audio” and then merges
                     them. /b is the fallback which means just get the best stream available */
        "bv*+ba/b",
        "-S",
        "vcodec:h264,acodec:aac,hdr:12,res:1080,fps:60", /* Our most preferred video codec is h264,
                                                          our most preferred audio codec is aac,
                                                          prefer hdr content with higher bit depth,
                                                          prefer up to 1080p resolution and 60 fps*/
        "--merge-output-format",
        "mp4",
        "--print", /* --print after_move:filepath tells yt-dlp to just print the final path
                    after downloading */
        "after_move:filepath",
        "--output",
        outputTemplate,
        sourceURL,
    ]
}

private extension String {
    var trimmedToNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

func ffmpegArguments(inputFilePath: String, outputFilePath: String) -> [String] {
    [
        "ffmpeg",
        "-y", /* Overwrite output files without asking */
        "-nostdin",
        "-hide_banner", /* suppress startup banner -- cleaner logs */
        "-loglevel", /* -loglevel error = just log the stuff that goes really wrong */
        "error",
        "-nostats", /* don't print periodic stats/progress */
        "-i",
        inputFilePath,
        "-map_metadata", /* -map_metadata -1 = remove all metadata from the output */
        "-1",
        "-map_chapters", /* remove chapter markers */
        "-1",
        "-map",
        "0:v:0", /* select first video stream and first audio stream (if video has audio, if not
                  command wont fail because we've made it optional with '?') */
        "-map",
        "0:a:0?", /* select first audio stream from the first input if it exists */
        "-c:v", /* c:v libx264 = encode video using H.264 via libx264 */
        "libx264",
        "-preset", /* preset medium = x264 speed/efficiency tradeoff, medium is a good default */
        "medium",
        "-crf", /* Constant Rate Factor = quality setting. 22 is good for most cases. lower = higher quality/larger size */
        "22",
        "-vf", /* vf scale=trunc(iw/2)... ensures width/height are even numbers some codecs require even dimensions for the container */
        "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
        "-pix_fmt", /* pix_fmt yuv.. forces 4:2:0 chroma subsampling for braod compatibility (iOS, web players and old devices) */
        "yuv420p",
        "-profile:v",
        "high",
        "-level",
        "4.1",
        "-movflags",
        "+faststart",
        "-tag:v",
        "avc1",
        "-c:a",
        "aac",
        "-b:a",
        "192k",
        "-ar",
        "48000",
        "-ac",
        "2",
        "-sn",
        "-dn",
        outputFilePath,
    ]
}

func transcodedFileURL(for inputFileURL: URL) -> URL {
    let baseName = inputFileURL.deletingPathExtension().lastPathComponent
    return inputFileURL.deletingLastPathComponent()
        .appendingPathComponent("\(baseName)-ios")
        .appendingPathExtension("mp4")
}

// - TODO: We may want explicit, complete paths instead of relying on /usr/bin/env
// LaunchDaemon service that starts and runs our vapor server doesn't have the same environment as the user so yt-dlp and ffmpeg paths must be explicitly made available in the launch wrapper script or in the LaunchDaemon plist
private func runCommand(arguments: [String], commandName: String) async throws -> CommandResult {
    try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
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
                    ? "\(commandName) failed with exit code \(process.terminationStatus)."
                    : "\(commandName) failed: \(stderr)"
                continuation.resume(throwing: Abort(.badGateway, reason: reason))
                return
            }

            continuation.resume(
                returning: CommandResult(
                    stdout: stdout,
                    stderr: stderr
                )
            )
        }

        do {
            try process.run()
        } catch {
            continuation.resume(
                throwing: Abort(
                    .internalServerError,
                    reason: "Failed to start \(commandName): \(error.localizedDescription)"
                )
            )
        }
    }
}

private struct MediaDownloadServiceKey: StorageKey {
    typealias Value = MediaDownloadService
}

private struct MediaDownloadDirectoryKey: StorageKey {
    typealias Value = String
}

private struct MediaDownloadJobStoreKey: StorageKey {
    typealias Value = MediaDownloadJobStore
}

extension Application {
    var mediaDownloadService: MediaDownloadService {
        get { self.storage[MediaDownloadServiceKey.self] ?? .live() }
        set { self.storage[MediaDownloadServiceKey.self] = newValue }
    }

    var mediaDownloadDirectory: String {
        get { self.storage[MediaDownloadDirectoryKey.self] ?? (self.directory.workingDirectory + "Storage/Downloads") }
        set { self.storage[MediaDownloadDirectoryKey.self] = newValue }
    }

    var mediaDownloadJobStore: MediaDownloadJobStore {
        get { self.storage[MediaDownloadJobStoreKey.self] ?? MediaDownloadJobStore() }
        set { self.storage[MediaDownloadJobStoreKey.self] = newValue }
    }
}
