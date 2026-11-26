# Qyvro — Architecture & Developer Notes

Native macOS AppKit file explorer built for large photo and video collections (generative art, editing, color grading, and design).

- **Bundle ID:** `com.qyvro.files`
- **Deployment Target:** macOS 13.0+ Universal (`arm64` + `x86_64`)
- **Build System:** Pure AppKit compiled directly with `swiftc` — no Xcode project, no SwiftPM, no external dependencies.

---

## Building

```bash
./build_app.sh
```

What `build_app.sh` does:
- Compiles **all `Sources/*.swift`** files automatically via glob (new Swift files in `Sources/` are picked up without registration).
- Builds optimized `x86_64` and `arm64` slices in parallel, merges them into a Universal binary with `lipo`, copies `Resources/Info.plist` and `Resources/Qyvro.icns`, ad-hoc signs the bundle, and prints the path to the resulting `Qyvro.app`.
- Pins `MacOSX15.4.sdk` when available so partial Command Line Tools updates don't break local builds.
- Saves a pre-build source archive into `../FPilotMac_Backups/` (do not modify or clean that backup directory manually).

---

## Smoke Tests

Each `Tests/<Name>Smoke/main.swift` is a standalone executable compiled against `Sources/*.swift` **excluding `Sources/main.swift`** (to avoid duplicate top-level entry points). A passing test prints `... : PASS` and exits `0`.

```bash
xcrun swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
  -target arm64-apple-macosx13.0 \
  -framework AVFoundation -framework Carbon -framework Cocoa \
  -framework CoreImage -framework CoreVideo -framework IOSurface \
  -framework Metal -framework Quartz -framework QuickLookThumbnailing \
  $(ls Sources/*.swift | grep -v 'Sources/main.swift') \
  Tests/GridGeometrySmoke/main.swift -o /tmp/qyvro-smoke && /tmp/qyvro-smoke
```

Available smoke suites (11):
- `ClipboardPasteSmoke`
- `ClipboardShortcutSmoke`
- `FileOperationHistorySmoke`
- `FinderTagStoreSmoke`
- `GridAndTabInteractionSmoke`
- `GridGeometrySmoke`
- `QuickLookGeometrySmoke`
- `QuickLookSessionCacheSmoke`
- `SavedTabGroupsSmoke`
- `SpotlightSearchSmoke`
- `WindowResizeSmoke`

---

## Source Map (`Sources/`)

| File | Responsibility |
|---|---|
| `main.swift` | Application entry point |
| `AppDelegate.swift` | Main menu, keyboard shortcuts, global `⌘E` summon, Command Palette wiring |
| `AuroraDesignSystem.swift` | Studio V4 & Aurora V3 layouts (`Studio`, `Podium`, `Rail`, `Sidebar`), header pills, recessed filter tray, empty state, selection action bar, Undo toast |
| `CoreServices.swift` | `FileItem`, async media metadata (`AVFoundation` + bounded `NSCache`), themes, typography, per-folder view/sort profiles (`FPFolderProfileStore`), parallel image resizer |
| `Workspace.swift` | Tabs, split panes, window sessions (`FPWindowSession`), toolbar, bookmarks |
| `FilePanel.swift` | Core explorer pane: state, view switching, keyboard handling, drag & drop |
| `FilePanel+Grid.swift` | Grouped date grid layout, horizontal row scrolling, keyboard grid navigation |
| `FilePanel+Navigation.swift` | History stack, Recents, Spotlight search, swipe triggers |
| `FilePanel+Operations.swift` | Copy/move/trash, Undo/Redo integration, resize/convert/ZIP, batch rename hook |
| `FilePanel+TableAndThumbnails.swift` | List table cells, disk thumbnail cache, 2-plane minimalist folder renderer (`FPFolderIconRenderer`) |
| `FilePanel+ContextMenu.swift` | Context menus, type-aware Photoshop/Premiere Pro actions, presets |
| `FileGridViews.swift` | Grid tile cells, section headers, corner mark toggles, pill controls |
| `FilePreviewSidebar.swift` | Preview & Inspector sidebar with recursive folder size and Finder tags |
| `PreviewWindow.swift` | Built-in media viewer, side-by-side comparison (`C`), split wipe curtain (`V`) |
| `PreviewAndSearchSupport.swift` | Decoded preview cache, panel geometry, Spotlight query support |
| `SwipeEffects.swift` | Hardware-accelerated Display P3 two-finger swipe wave transition (`IOSurface` / Core Image) |
| `DropShelfModule.swift` | Floating Drop Shelf (`⌥⌘S`) for cross-folder staging and batch drag-out |
| `DiskAnalyzerModule.swift` | Storage ring & 3-tab analyzer: Folders, Largest Files, CryptoKit SHA-256 Duplicates (`⌥⌘D`) |
| `BatchRenameSheet.swift` | Studio Batch Rename window (`⌘⇧R`) with live Before → After preview |
| `ClipboardModule.swift` | Local clipboard history (text, links, images) |
| `CloudClipboardSync.swift` | Optional cross-device cloud clipboard client (`⌃⌘V`) |
| `FinderTagStore.swift` | Two-stage marking backed by native macOS Finder xattr tags |
| `FileOperationHistory.swift` | Undo/Redo stack for file moves, renames, and trash operations |
| `SettingsAndCommands.swift` | Appearance/behavior settings window and Command Palette (`⌘K`) |
| `SavedTabGroups.swift`, `CutFileState.swift`, `RenameSheet.swift`, `BreadcrumbPathView.swift`, `JumpScroller.swift`, `UIComponents.swift`, `WindowPresentationAnimator.swift`, `WindowResizeOverlay.swift` | Focused UI and workflow modules |

---

## Conventions & Notes

- **Naming:** Legacy types carry the `FP` prefix; new subsystems use `Qyvro`.
- **Native Finder Tags:** Two-stage picks live directly inside file extended attributes (`com.apple.metadata:_kMDItemUserTags`) so they persist across moves, renames, and Finder/Spotlight queries.
- **Grid Hit Testing:** Grid cells own selection and drag gestures; any interactive overlay control inside a tile must explicitly handle `hitTest`.
- **Clean Distribution:** Never commit build artifacts (`*.app`, `*.zip`, `*.dmg`), personal preferences, or clipboard sync credentials (`cloud.json`, `token.txt`).
