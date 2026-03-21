# RipKitServer

A basic vapor web server project that grabs media and content requested by the user using ffmpeg
and yt-dlp

The general idea involves:
1. End user pastes URL into field
2. Client posts/sends URL to server with ffmpeg and yt-dlp setup
3. Server downloads content
4. Server returns a url to download/save the content

## Authenticated site downloads

If a site like Instagram requires a logged-in session, configure `yt-dlp` cookies on the server:

- `RIPKIT_YTDLP_COOKIES_FILE=/absolute/path/to/cookies.txt`
- `RIPKIT_YTDLP_COOKIES_FROM_BROWSER=safari`

The server passes those flags through to `yt-dlp` for every download. If both are set, the cookies
file takes precedence over browser extraction.

Use a cookies file only for an account you control and protect it like a password. This only grants
access to media that the logged-in account can already view.
