import Foundation
import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    let downloadDirectory = app.directory.workingDirectory + "Storage/Downloads"
    let ytDLPCookieConfiguration = YTDLPCookieConfiguration(
        cookiesFilePath: Environment.get("RIPKIT_YTDLP_COOKIES_FILE"),
        cookiesFromBrowser: Environment.get("RIPKIT_YTDLP_COOKIES_FROM_BROWSER")
    )

    try FileManager.default.createDirectory(
        atPath: downloadDirectory,
        withIntermediateDirectories: true,
        attributes: nil
    )

    app.mediaDownloadDirectory = downloadDirectory
    app.mediaDownloadService = .live(cookieConfiguration: ytDLPCookieConfiguration)
    app.mediaDownloadJobStore = MediaDownloadJobStore()
    try routes(app)
}
