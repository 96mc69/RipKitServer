import Foundation
import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    let downloadDirectory = app.directory.workingDirectory + "Storage/Downloads"
    try FileManager.default.createDirectory(
        atPath: downloadDirectory,
        withIntermediateDirectories: true,
        attributes: nil
    )

    app.mediaDownloadDirectory = downloadDirectory
    app.mediaDownloadService = .live
    try routes(app)
}
