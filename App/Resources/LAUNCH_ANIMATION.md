# Launch animation — where to drop your video

The app looks for a bundled launch clip and plays it once on cold start, then
hands off to the app. If none is present, it uses the native CN animation
(mark + "ClassNotes" typewriter) — so nothing breaks while you finish the video.

## To add your launch video

1. Name the file **`LaunchAnimation.mov`** (preferred, supports transparency)
   or `LaunchAnimation.mp4` / `.m4v`.
2. Put it in this folder: `App/Resources/LaunchAnimation.mov`.
3. In Xcode, drag the file into the project navigator and **tick the
   `ClassMateNotes` target** under "Add to targets" (so it ships in the app
   bundle). Or just tell me it's here and I'll wire the target reference.

That's it — `LaunchView` auto-detects it (see `LaunchMedia.videoURL`) and plays
it full-bleed over the theme's paper color. A square or portrait clip with a
transparent/paper background looks best.

## Loading animation

The in-app loading spinner (`BrandLoader`) is native and needs no file — it
draws the C, then the N, then cross-fades into your CN mark, tinted to the
current theme. It matches ClassMate's `CmLoading`, with N instead of M.

## Logo assets in use

- **App icon** (outside the app): `App/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png`
  — your CN on white.
- **In-app mark** (tinted to theme): `App/Assets.xcassets/BrandMark.imageset/icon_light.png`
  — your CN on transparent. Used by the launch fallback, loader, and the
  mark+wordmark lockup at the top of the app (`BrandLockup`).
