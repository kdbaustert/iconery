<p align="center">
  <img src="docs/icon.png" alt="Iconery app icon" width="160" height="160">
</p>

# Iconery

An icon library for macOS, in the spirit of IconJar. Keeps your icons in sets, finds them again,
and exports them in the format and sizes a project needs. It can also bring over an existing
IconJar library. Runs on macOS 14 and later.

There are no release builds yet; see [Contributing](#contributing) to build it.

## Features

### Library

- Import SVG, PNG, ICNS and ICO files by dragging them in or with File ▸ Import Icons. A folder
  becomes a set, and its subfolders become sets inside it.
- Sets nest as deep as you like. A set shows its own icons and those of every set inside it.
- All Icons, Recently Used and Starred sit above your sets in the sidebar.
- A zoomable grid (24 to 256 pt), sorted by name, file type or date added, with names shown always,
  on hover or never, and ⌘-click and ⇧-click selection.
- Search by name, and by tags, set names or descriptions if you choose. Every word typed has to
  match, so each one narrows the grid.
- Imports skip files the library already has, compared by content, and can name an SVG after the
  `<title>` inside it.
- Each icon carries a name, tags, a description and a license. Licenses start with the nine
  IconJar ships with, and you can add your own.
- An optional contrast fix draws one-color SVGs in black or white when they would be barely
  visible against the background. It only changes what you see, never what you export.

### IconJar

- Import an IconJar library, or one of its iCloud backups (`.ijlibrary`). Groups and sets come
  across nested as they were; icons keep their names, tags, stars and dates.
- Importing the same library again adds only what's new since.
- Iconery reads a copy of IconJar's database and never changes IconJar's own files.

### Export

- PNG, JPG, TIFF, GIF, PDF, ICO, ICNS, SVG, or the original file.
- ICO files hold sizes up to 256 px, and ICNS files every slot from 16 to 1024, including the
  64 and 1024 px slots that macOS's own ICNS writer leaves out.
- Icon Fill draws the whole icon in one color. A background color, a file name prefix and suffix,
  the size in the file name, and JPG quality are on the options button.
- IconJar's eleven built-in presets for macOS, iOS, Android and the web, from App Icon to Android's
  density sets, plus presets of your own.
- Drag an icon out of the grid or the preview and it arrives already exported with the current
  settings, as IconJar's QuickDrag does.
- Exports never overwrite: a clash becomes "home 2.png".
- Open In sends an icon to any app that can open it, and remembers the one you picked.

- File names from the icon's name, its original file name or its tags; set folders kept on
  export; tags added as Finder tags; and SVG cleanup (width and height, comments, the XML
  declaration, whitespace).

### Settings

- General: appearance (follow macOS, or always Light or Dark), grid sorting and names, what search
  looks at, how many icons Recently Used keeps, and whether deleting asks first.
- Library: move the library to any folder or switch to another, found again even after the folder
  is renamed or moved in Finder. Back up the whole library to a dated zip, in iCloud Drive by
  default, by hand or daily or weekly, keeping as many as you choose. Unzip a backup and switch to
  it to restore.
- Import: where loose files go, skipping duplicates, and SVG titles as names.
- Export: file naming, set folders, Finder tags, a fixed export folder or asking each time,
  showing exports in Finder, and SVG cleanup.

## Limits

- macOS's SVG renderer, which Iconery uses for the grid and for bitmap and PDF exports, skips SVG
  filters such as drop shadows. SVG and Original exports keep the file as it is.
- WebP and EPS are not offered: macOS can read WebP but has no writer for it, and none for EPS.
- No editing beyond the fill color on export. Iconery organizes and exports.

## Permissions

None to start with. If you move the library or its backups into Documents or iCloud Drive, macOS
may ask once for access to that folder.

## Privacy

No telemetry, analytics, crash reporting, or account. Iconery makes no network requests of its own;
the only time it opens the web is when you click a license's link.

## Contributing

Issues and pull requests are welcome. To build and test:

```sh
./build.sh --install         # builds build/Iconery.app, copies it to /Applications, launches it
swift test                   # the test suite
Resources/Icon/make-icon.sh  # re-renders the app icon after Resources/Icon/Iconery.svg changes
```

Building needs Xcode, for its asset catalog compiler. `build.sh` signs with a local certificate
when it finds one and ad-hoc otherwise; set `CODESIGN_IDENTITY` to choose. Re-rendering the icon
needs Google Chrome, because it is the renderer that keeps the artwork's shadows and transparency.

Built by [@kdbaustert](https://github.com/kdbaustert).
