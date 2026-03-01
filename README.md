# RipKitServer

A basic vapor web server project that grabs media and content requested by the user using ffmpeg
and yt-dlp

The general idea involves:
1. End user pastes URL into field
2. Client posts/sends URL to server with ffmpeg and yt-dlp setup
3. Server downloads content
4. Server returns a url to download/save the content
