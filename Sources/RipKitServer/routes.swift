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

        let job = await req.application.mediaDownloadJobStore.createQueuedJob()
        let jobID = job.jobID
        let downloadService = req.application.mediaDownloadService
        let downloadDirectory = req.application.mediaDownloadDirectory
        let jobStore = req.application.mediaDownloadJobStore

        Task {
            await jobStore.markProcessing(jobID: jobID)

            do {
                let downloadedMedia = try await downloadService.download(
                    requestedURL,
                    downloadDirectory
                )
                await jobStore.markCompleted(jobID: jobID, media: downloadedMedia)
            } catch let abort as Abort {
                await jobStore.markFailed(jobID: jobID, error: abort.reason)
            } catch {
                await jobStore.markFailed(jobID: jobID, error: error.localizedDescription)
            }
        }

        return job
    }

    app.get("api", "download", ":jobID") { req async throws -> DownloadResponse in
        guard let jobID = req.parameters.get("jobID"),
              let job = await req.application.mediaDownloadJobStore.job(jobID: jobID) else {
            throw Abort(.notFound)
        }

        return job
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
        if fileName.lowercased().hasSuffix(".mp4") {
            response.headers.replaceOrAdd(
                name: .contentType,
                value: "video/mp4"
            )
        }
        return response
    }
}

private func isSafeFileName(_ fileName: String) -> Bool {
    !fileName.contains("/") && !fileName.contains("\\") && !fileName.contains("..")
}
