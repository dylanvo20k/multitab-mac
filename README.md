# Multitab for Mac

A personal, media-only Reddit gallery. Each tab is a feed showing only images, GIFs and videos in a grid. Text posts and article links are skipped.

## Build

```
./build.sh
```
This creates `Multitab.app` in this folder. Drag it to Applications if you like. Run `./build.sh` again after changing the code.

## First run

Settings (⌘,) asks for a Reddit app ID and secret. To get them, create an app of type **script** at https://www.reddit.com/prefs/apps (redirect URI: `http://localhost:8787`). Username and password are optional and only needed for your Home feed. Credentials are saved privately in `~/Library/Application Support/Multitab/credentials.json`.

## Using it

- **Grid:** hover a GIF or video to preview it, click any tile to open it full-window. Galleries are split into separate tiles.
- **Viewer:** ← → browse · I shows the title and subreddit · O opens on Reddit · Esc closes. Videos play with sound and controls.
- **Tabs:** ⌘T new tab (`r/pics`, `r/gifs+aww`, `u/name`, `search: cats`, `popular`, `all`, `home`) · ⌘1–9 switch · ⇧⌘W close · right-click a tab to move it.
- **Toolbar:** Hot/New/Top/Rising per tab, tile-size slider, refresh (⌘R).
- NSFW posts are blurred until clicked. You can turn this off in Settings.
