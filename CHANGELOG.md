# Changelog

## [0.2.1](https://github.com/RichardODonoghue/burnrate/compare/v0.2.0...v0.2.1) (2026-09-12)


### Bug Fixes

* attach zip + dmg to releases ([523a9cc](https://github.com/RichardODonoghue/burnrate/commit/523a9ccc02115f9d8140af5d1c6861c0aca0e1f0))
* attach zip + dmg to releases (release-please tags don't trigger workflows) ([5d00fd8](https://github.com/RichardODonoghue/burnrate/commit/5d00fd8aa0e86c4fe2993af0cc9343896848d91a))

## [0.2.0](https://github.com/RichardODonoghue/burnrate/compare/v0.1.1...v0.2.0) (2026-09-12)


### Features

* autoscale trend Y axis to visible data ([d47d7eb](https://github.com/RichardODonoghue/burnrate/commit/d47d7eb42634c0f0a70b2bb786ae84896a768225))
* burn-rate alerts for excessive usage detection ([fc28c09](https://github.com/RichardODonoghue/burnrate/commit/fc28c095adb1cd0954326f213c3e9f00ea7e2f9a))
* BurnRate mark (gauge + flame) across menu bar, Dock, notifications, About ([32baa49](https://github.com/RichardODonoghue/burnrate/commit/32baa494c7d08a489fde0489ef002fca21faad8a))
* Dock presence while the app window is open ([8b90a4e](https://github.com/RichardODonoghue/burnrate/commit/8b90a4e6fa008c05bb508e38d6140b6a258e10ad))
* estimated costs for models without vendor-reported pricing ([ff8c4a0](https://github.com/RichardODonoghue/burnrate/commit/ff8c4a084cf048506db1dd53e37f1fcf02d9044c))
* flame menu-bar icon, menu item icons, compact dropdown stats ([531c7b3](https://github.com/RichardODonoghue/burnrate/commit/531c7b3deb04bb0c96fe55faf10d421ba0a3de5e))
* flame rising from a gauge dial at its base ([7bad93f](https://github.com/RichardODonoghue/burnrate/commit/7bad93f0909cf8966c9b178148cf4fa890f551c5))
* gauge needle laid over the flame ([53547ce](https://github.com/RichardODonoghue/burnrate/commit/53547cedf63ae87a8ae251b73d5131b4b768267a))
* implement the G2 Dial Core icon set — stateful menu bar icon ([8eee766](https://github.com/RichardODonoghue/burnrate/commit/8eee7663389d9437c7de2df5546db626a1ab20ab))
* menu bar UI with per-provider usage, widgets, polling ([9acc4dc](https://github.com/RichardODonoghue/burnrate/commit/9acc4dc9365d3563057630997dfd8a37e76399e4))
* per-model usage view, cost alerts, model burn alerts ([0a160c0](https://github.com/RichardODonoghue/burnrate/commit/0a160c0d2f341e0be1aa12b2e93fc499c9eb5860))
* Rolling trend chart ticks every 6 hours ([141912c](https://github.com/RichardODonoghue/burnrate/commit/141912c73c39fdbe8866bcfcbc46aac520a0c8c2))
* Send Test Notification menu item ([20a3194](https://github.com/RichardODonoghue/burnrate/commit/20a319480b686dfd697968f072d9eb11852dadb7))
* settings + usage view polish, remaining-over-time chart ([9521429](https://github.com/RichardODonoghue/burnrate/commit/95214296cba1c09de5fcbfe290267d8243894e27))
* settings UI and milestone notifications ([9dd4952](https://github.com/RichardODonoghue/burnrate/commit/9dd4952366756e2c65cf7eccdacc8ac76cb14353))
* single app icon = G2 flame on light plate with hairline border ([747fe88](https://github.com/RichardODonoghue/burnrate/commit/747fe8877961149087559727d340e54f80913f77))
* snapshot cards atop the usage view; weekly x-axis for trend chart ([530fcc0](https://github.com/RichardODonoghue/burnrate/commit/530fcc0d7667630b158976d4fabae98480d4ca40))
* unified app window, slider polish, reset notifications ([65cc7df](https://github.com/RichardODonoghue/burnrate/commit/65cc7dfacb1299782b9a737991947193a55f845d))
* usage model and local log parsers ([b34d229](https://github.com/RichardODonoghue/burnrate/commit/b34d2298ceee16d55bab6d0d1914e905d34d1612))
* use Rolling as the unified short-window label ([6f16c40](https://github.com/RichardODonoghue/burnrate/commit/6f16c40d6a0fb9583962d4c3e0bb577fb70acfe9))
* vendor quota APIs for Claude and OpenCode Go ([5d18557](https://github.com/RichardODonoghue/burnrate/commit/5d185574d1e15e08e9cb7334ec35ab1835836963))


### Bug Fixes

* compact relative reset times to shrink the dropdown ([d66ddeb](https://github.com/RichardODonoghue/burnrate/commit/d66ddeb29a691aa2953cf9a783ae5c8a13d6e8ec))
* dedupe Claude usage by requestId; tooltips only on actionable items ([2b56168](https://github.com/RichardODonoghue/burnrate/commit/2b56168712121c5025f7417e21774a433bd2edac))
* duplicate notifications, tokens field wrap, notification icon ([f0426ee](https://github.com/RichardODonoghue/burnrate/commit/f0426ee8dd398647d3463bf25cd56f21d93816b2))
* flexible frames in unified window so sidebar never shifts ([9df8704](https://github.com/RichardODonoghue/burnrate/commit/9df870430ba51ee4b904b3f75f6615e60a0f5d27))
* keep sidebar pinned when opening the usage pane ([1927f39](https://github.com/RichardODonoghue/burnrate/commit/1927f39872148ac79f954897fd9e27993ae1f9e5))
* keep trend tooltip inside the plot at graph edges ([ce8f70b](https://github.com/RichardODonoghue/burnrate/commit/ce8f70b297d8174a77a8764aa929525ece9ee11c))
* keep trend tooltip inside the plot at graph edges ([f548f93](https://github.com/RichardODonoghue/burnrate/commit/f548f939401d0fbbc61dfc4bff9264bea084498d))
* light plate variant of the G2 mark for notifications ([2dac84b](https://github.com/RichardODonoghue/burnrate/commit/2dac84b9ee101e9c191297f6d6030fbc0f1d9d16))
* load the bundle icns into NSApp.applicationIconImage ([7a33e4e](https://github.com/RichardODonoghue/burnrate/commit/7a33e4e829e5dd223ea6a8df141805ac465b4131))
* lsregister in make_app.sh; bump to 0.1.1 to invalidate notification icon cache ([9edd404](https://github.com/RichardODonoghue/burnrate/commit/9edd404b49fedd9dcc3e2b8d778fccb39a1fc665))
* normalize OpenCode rolling window label to 5hr ([3bbb299](https://github.com/RichardODonoghue/burnrate/commit/3bbb299ec5f9aad0e3e016276471c7f154857b78))
* notification banner icon ([3462fb0](https://github.com/RichardODonoghue/burnrate/commit/3462fb06f604f9599e672f0e13ea8cb278b28e8d))
* notification icon is the bare G2 flame — no plate ([42c926e](https://github.com/RichardODonoghue/burnrate/commit/42c926e563b983d0d9f98d30b241725f41fe990f))
* pad trend plot so 0%/100% lines aren't clipped at the frame ([97508c3](https://github.com/RichardODonoghue/burnrate/commit/97508c353a982a4abba6877fb892b215e69c24c3))
* persist alert state across launches ([090acc4](https://github.com/RichardODonoghue/burnrate/commit/090acc45f9c9b5d570492368ff411ed1849ba424))
* remaining-over-time chart colors and legend ([e9945b8](https://github.com/RichardODonoghue/burnrate/commit/e9945b8e19839ec4bc39ccbf910e9235583f6d1f))
* settings layout overflow from new alert sections ([a68d774](https://github.com/RichardODonoghue/burnrate/commit/a68d77459a89acaa1380e9ce92372cb912cb0069))
* simpler BurnRate mark — plain flame with a small dial ([2f28890](https://github.com/RichardODonoghue/burnrate/commit/2f288903af2163241e0c92dc496d6867db2d586d))
* slider readouts round to match committed values ([68b1c0a](https://github.com/RichardODonoghue/burnrate/commit/68b1c0a02d326d8aecc5860faf9834259e088893))
* test notification bypasses the 60s duplicate suppression ([167ca27](https://github.com/RichardODonoghue/burnrate/commit/167ca2790911564cb8956a852bcdf1d4391ad1aa))
* tokens field in model-burn alerts no longer wraps ([764c38b](https://github.com/RichardODonoghue/burnrate/commit/764c38bec61663b911448c4b34e4251024ade0e8))
* use monotone interpolation so lines can't overshoot 0%/100% ([df61adb](https://github.com/RichardODonoghue/burnrate/commit/df61adbf90375a827b2b611ac880901536421e7f))
