# Transition performance audit

Date: 2026-10-03. Machine: Apple Silicon, macOS 26.6.2, DELL S3422DWG at 2752×1152 points, 2x, 100 Hz.
Numbers come from `spacewalk status` (switch timings), `spacewalk render <dir>|full` (Core Animation render
cost per frame at full display size, measured through CARenderer), and `ps` (idle CPU).

## Where the time goes in a switch

| Stage | Before | After | Notes |
|---|---|---|---|
| Overlay on screen | 17 to 25 ms | 12 to 18 ms | Wait cut from 1.5 refreshes to one refresh plus 2 ms. The Dock needs 30 ms or more to act on the swipe, so the overlay is always up first. |
| Dock switch | 30 to 140 ms | unchanged | Time for the Dock to commit the synthetic swipe. Not ours. Shorter on the 4K display (30 to 50) than on the ultrawide (60 to 140). |
| First new frame | 10 to 25 ms, 160+ on a static desktop | 10 to 25 ms | A frame from after the swipe was posted now counts, so a desktop that stopped changing early no longer waits for the 250 ms timeout. |
| Hotkey to first moving frame | 90 to 300 ms | 60 to 110 ms, 12 to 13 ms predicted | Predicted: the destination was left through Spacewalk before, so its last picture is on hand. |

## Findings and fixes

1. **Implicit animations.** Every change to layer contents, corners or hidden state got Core
   Animation's default 250 ms action. The outgoing picture faded in from the previous one on every
   switch. Fixed: a delegate returns no action for every layer in the stage.
2. **Transparent cards.** Overlapping effects blended two window-only layers over the wallpaper:
   ghost doubles, old windows through gaps, brightness dips. Fixed: every effect except plain
   slide builds opaque cards (windows over the Space's own wallpaper); crossfades keep the outgoing
   card opaque.
3. **Cube depth sorting.** Core Animation orders 3D-transformed siblings by the depth of their
   centre, so a face behind the screen plane sorted under the wallpaper and vanished. Fixed:
   perspective lives in a separate scene layer above the wallpaper; the cube uses explicit eased
   transform keyframes instead of `transform.rotation` interpolation.
4. **Capture pool exhaustion.** Eager mode held every frame it swapped in. The stream has six
   buffers, so after six frames it stalled mid-animation. Fixed: at most three frames are held.
5. **Wallpaper upload.** Wallpapers were CGImages; the first use of a new one uploaded 50 MB to
   the GPU on the main thread (overlay time 116 ms). Fixed: wallpapers are IOSurfaces, zero copy.
6. **Trilinear minification.** Content layers asked for trilinear filtering, which rebuilds mipmaps
   of a 50 MB surface on every content swap, up to 100 times a second in eager mode. Fixed: linear.
   Scales never go below 0.8, where linear is indistinguishable.
7. **Clipping.** Every card clipped to its bounds, which forces an offscreen pass over the whole
   card each frame. Fixed: clipping is on only while a card has rounded corners.
8. **Blur.** A Core Image blur over the full picture cost 23 to 55 ms per frame at quarter
   resolution, against a 10 ms frame budget at 100 Hz. Removed.
9. **Static destinations.** See the frame row above.

## Render cost per frame at full display size

Measured with CARenderer; the first frame of each run includes a one-off warm-up and is excluded.

| Effect | ms per frame |
|---|---|
| slide | 0.4 to 0.6 |
| depth | 0.3 to 1.2 |
| carousel | 0.3 to 0.9 |
| fade | 0.4 to 0.7 |
| zoom | 0.7 to 0.9 |
| cube | 0.3 to 0.5 |
| flip | 0.5 to 0.8 |
| swap | 0.5 to 1.0 |
| reveal | 0.3 to 0.7 |
| stack | 0.4 to 1.3 |

All effects stay far below the 10 ms budget of a 100 Hz frame.

## Idle cost

The capture stream delivers frames only while the picture changes. Idle CPU: about 1% on a 4K
60 Hz display, about 2% on the 5K 100 Hz ultrawide. Memory: about 50 MB per Space for the
wallpaper cache plus up to three held frames during a transition.

## Not measurable from here

Dropped frames on screen. The render server does not report them to the app. The per-frame cost
above leaves a wide margin, and no effect does per-frame work beyond compositing.

## Finger-driven switching

With "Follow my fingers" on, the stage freezes its clock (`speed = 0`) with the transition laid out
as a one-second linear animation and places it with `timeOffset` on every gesture event, so any
effect tracks the fingers. On release, a display-link eases the position to 1 (commit) or 0
(cancel); the commit duration is 0.3 s scaled down by the fling velocity, floor 70 ms. The Dock
swipe is posted at commit and the live picture fades in as before. Verified with synthesized
gestures and the scrub renderer; a physical trackpad was not available to the test.

The overlay no longer waits a refresh before the swipe goes out: the committed overlay reaches the
glass at the next refresh and the Dock needs 30 ms or more.

## Predictive start

When you leave a Space through Spacewalk, the outgoing frame is copied out of the stream pool and kept
as that Space's last picture (three most recent Spaces). The next switch back builds the incoming
card from it and starts moving before the swipe is even posted. Once the Dock reports the switch,
the first live frame fades in over the prediction in 120 ms, so a window that changed while hidden
blends in instead of popping; later frames replace it outright. If the Dock has not answered by
the time the animation ends, the overlay holds its last frame until it does. A Space never left
through Spacewalk has no picture and takes the normal path.

Measured: 12 to 13 ms from hotkey to motion on predicted switches, 50 to 75 ms Dock time in
parallel with the animation.

## Memory

Every picture is a full-size BGRA surface, 50 MB at 5504×2304: the stream pool (6), the wallpaper
per Space, the last picture of up to three Spaces, and up to three frames held during a transition.
Resident size on this display is around 600 MB. A half-resolution cache would cut the two caches
four-fold with a softer picture only behind the cards and during the first 120 ms of a predicted
switch.
