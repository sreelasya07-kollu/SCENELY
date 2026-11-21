# 0039 Android sample-app design system
Status: accepted. UI only; no change to the capturekit library, Hud API, Intent extras or prefs keys.
- Stay on platform Views (no Compose, AppCompat, MDC, Lottie or font/image libraries): the UI is ~4.8k lines of programmatic Views and a framework swap would cost more than the visual gain.
- `DesignTokens` (pure Kotlin) is the single source: colours (dark only, teal accent `#2DD4BF`, status colours), Material 3 baseline type sizes, 4 dp spacing grid, radii, motion 150/250/400 ms, 48 dp touch target. `UiKit` reads it; `res/values/colors.xml` mirrors it for the theme.
- The theme parent is platform `Theme.Material.NoActionBar` with `colorAccent`/`colorControlActivated` set, so Switch, ProgressBar and dialogs pick up the accent without a library.
- Non-capture screens use tonal solid surfaces; the capture HUD keeps translucent glass over the preview. `PRIMARY` now means the accent (it used to alias the off-white label colour).
- Reduced motion: every animation helper collapses to 0 ms when `ANIMATOR_DURATION_SCALE == 0`. `DesignTokensTest` guards contrast (>= 4.5:1 text, >= 3:1 accent) and the spacing grid.
