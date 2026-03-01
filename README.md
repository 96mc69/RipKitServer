The general idea involves:
1. End user pastes URL into field
2. Client posts/sends URL to server with ffmpeg and yt-dlp setup
3. Server downloads content
4. Server returns a url to download/save the content

The UI will have to be in SwiftUI since i have an iPhone. I'm assuming it's not possible to run things like yt-dlp or ffmpeg locally on the iPhone which is why i thought using an API and server to actually transcode/download the media would be feasible.

I've often used the yt-dlp command on my computers but I always find something on my phone while im out and about or i just dont have my computer with me and it would be nice to save stuff from my phone.

