# The promo

This cut predates the removal of Raycast extension support (the Node host and store extensions): the "Raycast extension" and Hacker News shots below show what was removed. Only script commands remain.

[promo.mp4](promo.mp4) is 40 seconds of what is new in Nanolight 2.0 (the 0.2 releases), 1920 × 1080 at 60 fps. [promo-preview.gif](promo-preview.gif) is the same video, silent and smaller. `tools/promo.sh` makes both in a few minutes, once the Windows and Linux recordings are in `zig-out/promo` (below).

| Time | Shot |
| --- | --- |
| 0:00 | Titles on frosted glass, the MacBook Air and the Dell XPS 13 out of focus behind it: "Nanolight is now on Mac · Windows · Linux", then the icon and "Introducing Nanolight 2.0, with Raycast extension support" |
| 0:04 | The glass clears; the camera settles on the two laptops side by side in the dark |
| 0:05 | ⌘Space and Ctrl Space open the panel on both at once; the camera pushes into the Mac's display until it fills the frame |
| 0:06 | The panel fills the frame: "New in Nanolight 2.0" |
| 0:08 | ⌘, opens Settings in the panel |
| 0:11 | "hacker": a Raycast extension (Hacker News) runs in the panel; ⌘K shows its actions |
| 0:16 | "system": a Raycast script command, run by Nanolight itself, its output in the panel |
| 0:19 | The pivot: the MacBook pulls back, the camera pans across to the XPS showing Windows |
| 0:23 | "Now on Windows": the System Info script command on Windows |
| 0:27 | "And Linux": Hacker News on Linux (Xfce), and its actions on Ctrl K |
| 0:35 | The panel's rectangle becomes the icon beside the name; "Mac · Windows · Linux" |

The apps, math and Google's suggestions were the first film's subject (v0.1); this one shows only what 2.0 adds. The titles are drawn by `tools/promo/title.swift`.

## How it's shot

Before this cut, a research pass (grok-4.7, through graff) looked at what makes software launch films feel well made: Apple's Liquid Glass and Spotlight films, Raycast's and Linear's launch and changelog videos, Cursor 2.0's film, Screen Studio's and Rotato's camera, and Emil Kowalski's easing guidance. This cut follows its conclusions:

- **The interface is the shot.** The panel fills most of the frame, and one thing happens per shot. There are no title cards or stat cards.
- **Quiet type.** One small label sits under the panel and names what is shown. Its size is undone by the camera's zoom, so it reads the same at every zoom.
- **A still camera.** Once the laptop's push-in is done, the camera holds the whole stage and doesn't move; only the pivot between the laptops pans. An earlier cut zoomed with each shot and followed the panel's height, and the frame bobbed with every key. Things that enter ease on `cubic-bezier(0.23, 1, 0.32, 1)`.
- **Sound under the picture.** There's a soft 86 BPM pad (Fmaj7, Dm9, B♭maj7, Csus2) with a quiet plucked arpeggio, room tone, a tick for each key, a glass tick when the panel opens, and a bell on the name. There's no kick drum and no riser.

`src/promo_camera.zig` is the camera, eases, loupe, vignette and grain. `src/promo_scene.zig` is what it looks at, and `src/promo.zig` is the timeline.

## What is real

- **The panel is the app's own code** (`src/view.zig`), drawn by nanoui offscreen and driven by key presses through nanoui's Tester. No window was shown and nothing was screen-recorded. The rows, the ranking, the faint completion, the math, the selection and the panel's springs are what the app does with those keys.
- **The apps listed** are Apple's own plus Google Chrome (`apps` in `src/promo.zig`), so they're the same on any Mac.
- **Google's suggestions** are what `suggestqueries.google.com` returned for "liquid gl" and "liquid glass" on 2 November 2026, decoded by the app's own `suggest.zig`. They show 0.3 s after typing pauses.
- **The results page** is Google's page for "liquid glass apple", loaded in an offscreen WebKit view with a Safari user agent as the panel's preview does (`tools/promo/serp.swift`), and placed where the panel shows it.
- **Hacker News** is what its extension (raycast/extensions) rendered through Nanolight's host on 3 November 2026, its first nine stories (`src/promo_hn.json`), drawn by the app's own `raycast_view.zig`. The **System Info** output is what that script command printed on the Mac that made the video (`src/promo_sysinfo.txt`).
- **The Windows and Linux shots are screen recordings** of the real app (Nanolight 0.2.2, installed from its GitHub release) on a Windows Server 2025 desktop and a Debian 13 (Xfce) desktop, in Daytona's sandboxes, recorded by their own screen recorder at 1024 × 768 and 30 fps while a script pressed the keys. They are put in `zig-out/promo` as `rec-win.mp4` (the System Info take), `rec-win-open.mp4` (a take that starts on the bare desktop, for the opening and the pivot; `WIN_KEY` says when its panel opens; the same take can be both) and `rec-linux.mp4`, and aren't stored in this repository. The video shows them cropped to the panel, 2× and 1.72× as fast as they were typed. The hotkey there is Ctrl Space, since the window manager holds Alt Space.

## What is made for the video

- **The laptops** are Apple's MacBook Air (13-inch, midnight) AR model from apple.com and Dell's XPS 13 (DX13260) AR model from dell.com, rendered in Blender (`tools/promo/laptop.py`). The MacBook's display shows the promo's frames, the XPS's the Windows recording. The Mac's desktop wallpaper is the one baked into Apple's model. The models are downloaded when the script runs and aren't stored in this repository.
- **The laptop shots, the pan between the laptops, labels and end card** are added for the video. The labels over the recordings are drawn by `tools/promo/caption.swift`.
- **The music and sound effects** are synthesised with ffmpeg in `tools/promo.sh`.
