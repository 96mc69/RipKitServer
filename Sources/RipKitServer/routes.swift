import Foundation
import Vapor

func routes(_ app: Application) throws {
    app.get { _ async in
        "RipKitServer is running."
    }

    app.post("api", "download") { req async throws -> DownloadResponse in
        let payload = try req.content.decode(DownloadRequest.self)
        let requestedURL = payload.url.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !requestedURL.isEmpty else {
            throw Abort(.badRequest, reason: "A URL is required.")
        }

        let downloadedMedia = try await req.application.mediaDownloadService.download(
            requestedURL,
            req.application.mediaDownloadDirectory
        )

        return DownloadResponse(
            fileName: downloadedMedia.fileName,
            downloadPath: "/downloads/\(downloadedMedia.fileName)"
        )
    }

    app.get("downloads", ":filename") { req async throws -> Response in
        guard let fileName = req.parameters.get("filename"), isSafeFileName(fileName) else {
            throw Abort(.badRequest, reason: "Invalid file name.")
        }

        let filePath = URL(fileURLWithPath: req.application.mediaDownloadDirectory, isDirectory: true)
            .appendingPathComponent(fileName)
            .path

        guard FileManager.default.fileExists(atPath: filePath) else {
            throw Abort(.notFound)
        }

        let response = try await req.fileio.asyncStreamFile(at: filePath)
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"\(fileName)\""
        )
        return response
    }
}

private func isSafeFileName(_ fileName: String) -> Bool {
    !fileName.contains("/") && !fileName.contains("\\") && !fileName.contains("..")
}
