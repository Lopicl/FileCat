# FileCat: a file manager for iPhone and iPad

A native SwiftUI file manager with built-in viewers for photos, videos, PDFs, music, text/Markdown and archives, a text editor, and native clients for SMB, NFS, WebDAV and Nextcloud.
It has no third-party dependencies: the network protocols are implemented in Swift on top of Apple frameworks (Network, CryptoKit, CommonCrypto), and archives use libarchive, which is part of iOS.

## Features

**Navigation**
- Four tabs: **Local Storage**, **Connections**, **Tags** and **Settings**. On iPhone they sit in the tab bar at the bottom. On iPad they're in the Liquid Glass bar at the top, which expands into a sidebar listing every server, folder and tag (each tag with its own icon and color), with Settings at the bottom of the sidebar.
- **Where am I**: on iPhone the screen's title is a Liquid Glass pill in the navigation bar; on iPad it's the bar's title dropdown. Either one lists every folder on the way to where you are (including ones you skipped, e.g. after opening a search result); tap one to jump back to it. In Connections it also lists your other servers and folders and has *Add Connection*; in Tags it lists every tag and *All Tags*.
- **Activity**: copies, moves, downloads, uploads, extracting and compressing run in the background. While anything runs (or has run), a progress ring with the number of running activities sits in the iPhone tab bar (on iPad, in the bottom corner); tap it for the list of current and past activities, with Cancel and Clear. A **Live Activity** shows the progress on the Lock Screen and in the Dynamic Island while FileCat is in the background (iOS gives apps about 30 seconds of background time, longer while music plays).
- Search is at the top of the ⋯ menu (the Tags tab keeps a magnifying glass button). It opens a search field at the bottom (with an ✕ to close it) and hides the tab bar while you search.

**Local Storage**
- The app's own storage. It also shows up in the Files app (*On My iPhone › FileCat*) and in Finder.
- List and icon (grid) views with Quick Look thumbnails; sort by name, date, size or kind (folders first). Tap the active sort again to reverse it.
- Recursive search inside the current folder, matching file names and tags
- A + menu with *Create Folder*, *Create Text File* and *Import from Files* (*Upload from Files* on servers); rename, duplicate, move, copy, share, delete, and file info
- **Edit as Text** for any file (long-press it, or *Edit* in the text and Markdown viewers), with find and replace. The file keeps its text encoding and its tags; files that aren't text can still be edited byte for byte, with a warning.
- **Archives**: ZIP, RAR (4 and 5), 7-Zip, TAR (plain, .gz, .bz2, .xz, .zst), ISO, CAB, LHA, XAR and single compressed files (.gz, .bz2, .xz) open like folders. Files inside open in the usual viewers; *Extract All*, *Extract* on any item, or *Extract Here* from the file's menu unpack them next to the archive (password-protected ZIPs ask for the password). *Compress* (menu or selection) makes a ZIP, 7-Zip or TAR.GZ archive, with progress and Cancel.
- Multi-select with a bottom action bar, context menus, and swipe actions
- The folder view refreshes live when files change on disk
- "Open in FileCat" from any app's share sheet

**Connections**
- Lists the servers and folders you added, and servers found nearby. Everything is added from the **+** menu: a server of each kind, or *Folder from Files* (iCloud Drive and other cloud storage from the Files app, USB drives, servers connected in Files).
- **SMB** (SMB 2.0 to 3.1.1 with NTLMv2 sign-in and message signing): Windows, macOS, Samba, NAS. *Browse* lists a server's shares; leave the share empty to see them all.
- **NFS** version 3 over TCP, with the portmapper or a fixed port. *Browse* lists exports. The server must allow unprivileged ports (the `insecure` export option).
- **WebDAV** over HTTP or HTTPS, with Basic/Digest sign-in and the option to trust a self-signed certificate
- **Nextcloud**: *Sign In with Nextcloud* opens your server's sign-in page and gets an app password (Login Flow v2), or enter one yourself
- Nearby SMB, NFS and WebDAV servers are found automatically (Bonjour)
- Files on servers download when you open them, with progress. Photos and videos swipe through the whole server folder, and music plays the folder as a queue, each fetched as needed.
- **Streaming**: videos and music start playing straight away while they download (Settings › *Stream Videos and Music*, on by default). Playback reads from the download as it arrives and jumps ahead with ranged reads when you seek; the finished download lands in the cache as usual. Leaving a video stops its download.
- **Keep Offline** for a file, a folder or a whole server: it stays on the device and is brought up to date when it changes on the server (on launch and when you pull to refresh the Connections tab). *Remove Download* frees the space again.
- New folder, upload, rename, delete, share and *Save to Local Storage* on servers
- **Folders from Files**: iCloud Drive (or any folder in it), folders from other apps and cloud services, USB drives, or servers connected in the Files app. Files that are only in iCloud are marked, download when opened, and offer *Download Now* and *Remove Download*.
- **USB drives reconnect by themselves**: an unplugged drive stays in the list as *Not connected* and comes back when it's plugged in again (checked when the app becomes active and every few seconds on the Connections tab). iOS doesn't let apps open a drive that was never picked, so each drive has to be added once with *Folder from Files*.
- Passwords are kept in the keychain.

**Tags**
- Color tags like the Files app plus your own, in any color (the color wheel next to the Finder colors; Finder and Files see the nearest Finder color), each with an optional SF Symbol icon (also when creating a tag from a file's Tags sheet)
- A file's tags show in front of its date and size
- Tag from the context menu, or several items at once in selection mode
- The Tags tab lists every tag; open one to see everything carrying it across Local Storage and added folders. Rename, recolor or delete tags there.
- Tags are stored Finder-style on the file itself (`com.apple.metadata:_kMDItemUserTags`), so they survive moves, renames and copies

**Settings**
- **Tags** on or off: off hides the Tags tab, tag menus and tag dots (tags on files are kept); show tags on files
- **Equalizer** (also in the music player); stream videos and music from servers; autoplay gallery videos; start gallery videos muted
- **Clear Cache** (thumbnails and recently opened server files) and **Remove All Offline Files**, with their sizes
- **Reset All Settings**: every preference, plus list/icon view, sort order, text size, equalizer and iPad tab layout. Files, tags and servers are kept.
- **Companion Apps**: MusiCat, and how other apps connect to your library (see below)
- At the very end there's a long cat. Keep pulling.

**Viewers**
| Type | Viewer |
|---|---|
| Photos & videos (JPEG, HEIC, PNG, GIF, RAW, MOV, MP4, M4V…) | One gallery for the whole folder: swipe between photos **and** videos. Photos: pinch/double-tap zoom, tap for full screen. Videos play inline (muted and autoplaying by default) with play/pause, scrubbing, mute/unmute and a Full Screen button for the system player. In landscape on iPhone the tab bar and mini player step aside. |
| PDF | PDFKit with continuous, single-page, or two-page layout, find, page indicator, and password unlock |
| Music (MP3, M4A, AAC, WAV, FLAC, AIFF…) | Queue of the folder's tracks, artwork/metadata, scrubbing, repeat, 10-band equalizer with presets, AirPlay, background playback, Lock Screen controls. A mini player stays above the tab bar; swipe it left to stop. On iPhone in landscape the full player splits artwork and controls. |
| Markdown | Native rendering (headings, lists, task lists, quotes, code, tables, links) with a source toggle |
| Text / code / logs / CSV / JSON… | Fast reader with find, font size, and monospace. Encoding is detected automatically. *Edit* opens the editor. |
| Archives (ZIP, RAR, 7-Zip, TAR…) | Browsed like folders; extract all or single items |
| Everything else (Office, iWork, RTF, USDZ…) | Quick Look |

## Companion apps (FileCatKit)

The first one is **MusiCat** (`MusiCat/`, bundle ID `com.lopicl.MusiCat`), a music player with playlists, several artists per song, and hi-res WAV/FLAC/ALAC playback at each file's own sample rate for USB DACs. It imports FileCat's servers and plays music from them. It's a placeholder for now; see `MusiCat/README.md`.

FileCat's storage is ready to be shared with other apps you build, such as a dedicated music or video player. `Packages/FileCatKit` is a Swift package that both FileCat and those apps use:

- `FileCatLibrary` gives a companion app lasting access to FileCat's Local Storage. The app shows a folder picker once, the user picks *On My iPhone › FileCat*, and the access is remembered with a security-scoped bookmark.
- `files(ofKinds:)` lists the library's music, videos, photos…, with each file's tags.
- `LibraryManifest` is `.FileCat/library.json` in Local Storage. FileCat keeps it up to date with a library ID, every tag's color and icon, the names of the folders added in Connections (access to those stays with FileCat, so a companion app asks for the same folders once), and every server's settings without its password (`SharedServer`).
- `ServerShareRequest` / `ServerShareReply` hand FileCat's servers, passwords included, to a companion app: the app opens `filecat://share-servers?reply=<its scheme>`, FileCat asks the user, then opens `<scheme>://filecat-servers?…`. FileCat only answers the companion apps it knows. After that the app follows the manifest: changed servers change, removed ones go, and a new password (`passwordChanged`) means asking again. FileCat's protocol code in `FileCat/FileCat/Network` (SMB, NFS, WebDAV, streaming) compiles into companion apps as it is.
- `FileActivityAttributes` describes FileCat's Live Activity, shared with the widget extension.
- `FileKind`, `FileTags`, `FileTag` are shared with FileCat, so files are classified and tagged identically.
- `FileCatLink` builds `filecat://open?path=…` and `filecat://reveal?path=…` links that open FileCat at a file ("Show in FileCat").

```swift
import FileCatKit

let library = FileCatLibrary()

// Once, e.g. from a "Connect FileCat Library" button:
.fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
    if case .success(let folder) = result { try? library.connect(to: folder) }
}

let songs = library.files(ofKinds: [.audio])
UIApplication.shared.open(library.link(.reveal, for: songs[0].url)!)
```

This works with a free (personal) developer team; no App Group or iCloud entitlement is needed. If you later move to a paid Apple Developer account, FileCat also shows its own iCloud Drive folder automatically once the app has an iCloud container.

## Requirements
- **Xcode 16 or later** (folder-synchronized groups, iOS 18 SDK)
- iOS / iPadOS **18.0+**

## Getting started
1. Open `FileCat/FileCat.xcodeproj` in Xcode.
2. Select the **FileCat** target → *Signing & Capabilities* → choose your **Team**. You can change the bundle ID (`com.lopicl.FileCat`) if you like.
3. Choose an iPhone or iPad simulator (or your device) and press **Run** (⌘R).
4. To get test files into the simulator, drag them onto the simulator window and save them to *On My iPhone › FileCat*, or use + › *Import from Files* inside the app.

Any `.swift` file you add under `FileCat/FileCat/` is picked up automatically, so you don't need to edit the project file. Raise the build number (`CURRENT_PROJECT_VERSION`) with every build you hand out.

## Tests
- **UI tests** (`FileCatUITests`) drive the app on a simulator: file management, search, every viewer, the gallery, the music and mini player, the equalizer, tags, settings (including reset and clear cache), `filecat://` links and iCloud placeholders. `NetworkUITests` covers WebDAV, Nextcloud sign-in, SMB (share browsing) and NFS against local test servers, and skips itself when they aren't running. It also imports a server into MusiCat and plays a song from it (install MusiCat on the simulator first, or that test skips). Each run starts from a fresh set of sample files.
- **Protocol tests** (`Tools/protocol-tests`) build the network code for macOS and exercise listing, ranged reads, downloads, uploads, rename, folders and recursive delete against real servers. `run.sh stream` checks streaming: ranged reads during a download, a video through AVFoundation's resource loader (needs a movie at `/tmp/filecat-test-server/Videos/clip.mp4`), and M4A/FLAC/WAV decoding with seeking.
- **FileCatKit tests**: `cd Packages/FileCatKit && swift test`.

```
brew install rclone samba                 # once
Tools/protocol-tests/servers.sh           # local WebDAV, Nextcloud mock, NFS and SMB 3.1.1 servers
Tools/protocol-tests/run.sh               # protocol tests
xcodebuild test -project FileCat/FileCat.xcodeproj -scheme FileCat -destination 'platform=iOS Simulator,name=iPhone 17'
Tools/protocol-tests/servers.sh stop
```

Debug builds also accept `-FileCatOpenPath "<path inside Local Storage>"` as a launch argument to open a file or folder directly, which is handy for screenshots, and `-FileCatDemoActivity <seconds>` to run a fake copy for trying the activity indicator and Live Activity.

## Project layout

```
FileCat/                        The FileCat app
  FileCat.xcodeproj
  FileCat/
    App/        App entry, tab shell, router, Tags tab, Settings, Companion Apps, long cat
    Model/      FileItem, FileService (file operations, iCloud downloads), sorting,
                LocationStore (added folders), FolderModel, DirectoryMonitor, TagStore,
                library manifest
    Browser/    FolderView (list/grid, menus, selection), title menu, search pill, rows/cells,
                thumbnails, move/copy picker, info sheet, tag views
    Network/    NetworkView (Connections tab), server editor, remote browser, download cache and
                offline sync, streaming (RemoteStream), WebDAV, SMB2/3 (client, NTLM/SPNEGO,
                signing), NFSv3 (ONC RPC), Nextcloud login, Bonjour discovery
    Archive/    libarchive wrapper (list, extract, compress), archive browser, bridging header
    Activities/ Activity center (progress, history, Live Activity, background time) and its list
    Viewers/    Photo & video gallery, PDF, text, text editor, Markdown (parser + renderer), Quick Look
    Audio/      AudioPlayer (AVAudioEngine playback, queue, Now Playing), streaming decoder,
                equalizer, players
    Assets.xcassets
  FileCatWidgets/               Widget extension: the Live Activity (Lock Screen, Dynamic Island)
  FileCatUITests/               UI tests
  FileCat-Info.plist            Background audio, file sharing, "Open in", filecat:// links, local network
  FileCatWidgets-Info.plist
MusiCat/                        MusiCat, the companion music player (placeholder; see MusiCat/README.md). Also
                                compiles FileCat's protocol files from FileCat/FileCat/Network (group "FileCat Network")
Packages/FileCatKit/            Shared library for FileCat and companion apps (+ tests)
Tools/make-app-icon.swift       Draws FileCat's icon: xcrun swift Tools/make-app-icon.swift FileCat/FileCat/Assets.xcassets/AppIcon.appiconset/AppIcon.png
Tools/make-musicat-icon.swift   Draws MusiCat's icon: a vinyl record with a cat-shaped hole
Tools/protocol-tests/           Local test servers and the protocol test harness
```

## Ideas for later
- SMB 3 encryption (for shares that require it), SFTP and FTP
- A File Provider extension, so servers also appear in the Files app
- A trash, drag and drop between windows on iPad
- Creating RAR archives (libarchive only reads them)
