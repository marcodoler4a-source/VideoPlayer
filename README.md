# Video Player for iOS
Native SwiftUI/AVKit local video player.

## Features
- Import videos from Files
- Local library with thumbnails
- Full-screen playback
- Tap/drag seek bar
- 10-second skip forward/back
- 0.5x–2x playback speeds
- Remembers playback position
- Portrait and landscape orientations
- Files sharing enabled

## Codemagic
1. Push this entire project to GitHub.
2. Add the repository to Codemagic.
3. Choose the `ios-workflow` from `codemagic.yaml`.
4. Start a build.
5. The artifact is `VideoPlayer-unsigned.ipa`, suitable for signing/installing with your sideloading workflow.
