# Third-party components

The iOS app uses Apple system frameworks: SwiftUI, AVFoundation/AVFAudio,
AudioToolbox, MediaPlayer, ActivityKit, WidgetKit, AppIntents, PhotosUI and Security.
No Apple SDK binaries are included in this source archive.

The supplied clover image is reused from the existing verness project.

The server invokes yt-dlp, supplied separately by the existing Windows project
or installed through `Server/requirements.txt`. Source and license information:
https://github.com/yt-dlp/yt-dlp . Node.js is used as its JavaScript runtime:
https://nodejs.org/ . Neither yt-dlp.exe nor Node.js is embedded in this archive.

Lyrics are retrieved from LRCLIB: https://lrclib.net/docs . Track artwork and
lyrics remain the property of their respective owners.

Optional Windows validation used tree-sitter, tree-sitter-swift and
openstep-parser in a temporary tools folder. These tools are not dependencies
of the app or included in this archive.
