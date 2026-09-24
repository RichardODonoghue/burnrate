# Changelog

## [0.7.4](https://github.com/RichardODonoghue/burnrate/compare/v0.7.3...v0.7.4) (2026-09-24)


### Bug Fixes

* find OpenCode creds via XDG and explain missing providers ([#71](https://github.com/RichardODonoghue/burnrate/issues/71)) ([bab6277](https://github.com/RichardODonoghue/burnrate/commit/bab62773d92832e1b75ec70e02d22b2cb76f3c32))

## [0.7.3](https://github.com/RichardODonoghue/burnrate/compare/v0.7.2...v0.7.3) (2026-09-24)


### Bug Fixes

* bundle the Swift runtime in Linux packages ([#69](https://github.com/RichardODonoghue/burnrate/issues/69)) ([bf8f629](https://github.com/RichardODonoghue/burnrate/commit/bf8f6297050ce4fd3353aeab3a01eef8d35bd327))

## [0.7.2](https://github.com/RichardODonoghue/burnrate/compare/v0.7.1...v0.7.2) (2026-09-17)


### Bug Fixes

* parse OpenCode's migrated session_message table ([#64](https://github.com/RichardODonoghue/burnrate/issues/64)) ([f7b6795](https://github.com/RichardODonoghue/burnrate/commit/f7b67951ec48d2f6f4c16d78d941d96280611519))
* stop Usage page re-rendering on every mouse event ([#62](https://github.com/RichardODonoghue/burnrate/issues/62)) ([3a5d534](https://github.com/RichardODonoghue/burnrate/commit/3a5d5341cf31e4f6364af0e88864c5ec35a75df2))

## [0.7.1](https://github.com/RichardODonoghue/burnrate/compare/v0.7.0...v0.7.1) (2026-09-17)


### Bug Fixes

* restore Claude Keychain credentials; make Charts row opt-in ([#60](https://github.com/RichardODonoghue/burnrate/issues/60)) ([0b584d5](https://github.com/RichardODonoghue/burnrate/commit/0b584d56e4dc5178ddc534ed1c7643cc3f1736c7))

## [0.7.0](https://github.com/RichardODonoghue/burnrate/compare/v0.6.0...v0.7.0) (2026-09-17)


### Features

* daily stacked-usage chart and model totals on Linux ([#54](https://github.com/RichardODonoghue/burnrate/issues/54)) ([98506e3](https://github.com/RichardODonoghue/burnrate/commit/98506e33aa2cce60ce77691d69c20fdc851d9296))
* edit burn-rate and cost rules on Linux ([#53](https://github.com/RichardODonoghue/burnrate/issues/53)) ([9d5900c](https://github.com/RichardODonoghue/burnrate/commit/9d5900c64ebe847086488201f8e879a26594a477))
* first Linux front-end (GTK4 window) ([#45](https://github.com/RichardODonoghue/burnrate/issues/45)) ([b671d84](https://github.com/RichardODonoghue/burnrate/commit/b671d84eba0c9e2b9d78771d6561fd9d228c5607))
* Linux charts window (Cairo trend + ranking) ([#52](https://github.com/RichardODonoghue/burnrate/issues/52)) ([613161d](https://github.com/RichardODonoghue/burnrate/commit/613161d93eeabf2de1edb9f2437de697daa61d99))
* Linux milestone-step editing and daily-cost alerts ([#51](https://github.com/RichardODonoghue/burnrate/issues/51)) ([fa16e52](https://github.com/RichardODonoghue/burnrate/commit/fa16e520c74254fd5306b3032e16f714374b8845))
* Linux notifications and packaging ([#49](https://github.com/RichardODonoghue/burnrate/issues/49)) ([46a265c](https://github.com/RichardODonoghue/burnrate/commit/46a265c3235805e66ed3b71abff34c1b70da0bd5))
* Linux tray (StatusNotifierItem + DBusMenu over GIO) ([#48](https://github.com/RichardODonoghue/burnrate/issues/48)) ([8a01425](https://github.com/RichardODonoghue/burnrate/commit/8a014254813c7b177652735f1dad0c1fb794be29))
* Linux widgets, settings, updater and .deb packaging ([#50](https://github.com/RichardODonoghue/burnrate/issues/50)) ([14eb150](https://github.com/RichardODonoghue/burnrate/commit/14eb150be0937933b989dada19f7100c959bd09b))
* Windows settings dialog ([#57](https://github.com/RichardODonoghue/burnrate/issues/57)) ([ef16e93](https://github.com/RichardODonoghue/burnrate/commit/ef16e93192c497941de6910c65299983e992ec10))
* Windows settings JSON and per-provider widget trays ([#56](https://github.com/RichardODonoghue/burnrate/issues/56)) ([3f93c64](https://github.com/RichardODonoghue/burnrate/commit/3f93c6442158a9244958f493d463e0f0b91af606))


### Bug Fixes

* link Windows app as GUI subsystem (no console window) ([#59](https://github.com/RichardODonoghue/burnrate/issues/59)) ([f293da3](https://github.com/RichardODonoghue/burnrate/commit/f293da336e4c1278edd52176a33f95794b821207))

## [0.6.0](https://github.com/RichardODonoghue/burnrate/compare/v0.5.0...v0.6.0) (2026-09-15)


### Features

* Monthly trend disclaimer for Claude ([6369caf](https://github.com/RichardODonoghue/burnrate/commit/6369caf9f1447175251a9cb2ec7bb69acf97722d))
* note on Monthly trend that Claude has no monthly limit ([431bfab](https://github.com/RichardODonoghue/burnrate/commit/431bfabbdaadc53c46158c4b363b0ce365885d9e))
* plan capacities UI + working Codex local usage, plus cleanup ([11a8601](https://github.com/RichardODonoghue/burnrate/commit/11a8601a5ea4495a87e15e3e598ee313ba8f64f4))
* plan capacities UI + working Codex local usage, plus cleanup ([86f4446](https://github.com/RichardODonoghue/burnrate/commit/86f44467e3ad3a2c8024fb0fd844f80892b36101))

## [0.5.0](https://github.com/RichardODonoghue/burnrate/compare/v0.4.0...v0.5.0) (2026-09-14)


### Features

* accurate About page + GitHub links ([7ef28e8](https://github.com/RichardODonoghue/burnrate/commit/7ef28e83bc826eff797a0024f0511fb580c2540c))
* describe BurnRate accurately on About, add GitHub links ([886cf6a](https://github.com/RichardODonoghue/burnrate/commit/886cf6ab637ce5a8ebdef31f6b2900998f7a1094))
* remove model-burn alerts ([6e283a5](https://github.com/RichardODonoghue/burnrate/commit/6e283a5c50cdb17bd27a3892f010434094462895))
* remove model-burn alerts ([022080a](https://github.com/RichardODonoghue/burnrate/commit/022080a2d38bf5821880bddf2d23e38d7c471b56))
* same card treatment for notifications, widgets and about panes ([2f4b058](https://github.com/RichardODonoghue/burnrate/commit/2f4b0585312bd831663d92cd3633b66e9b9d48b8))
* same card treatment for notifications, widgets and about panes ([1a5fe6b](https://github.com/RichardODonoghue/burnrate/commit/1a5fe6b1bf4e0122c38b9a7d23dbe4357c76ecb8))


### Bug Fixes

* dashboard polish — hide synthetic rows, legible legend, Tahoe cards, fitted x-scale ([3eeacd2](https://github.com/RichardODonoghue/burnrate/commit/3eeacd2a479374e7bc907ab7d89cdacc3b1d72d4))
* dashboard polish — synthetic rows, legend, cards, fitted x-scale ([6e2d695](https://github.com/RichardODonoghue/burnrate/commit/6e2d695aaf9429d08a0eae9d4622c3dd0c2179d2))

## [0.4.0](https://github.com/RichardODonoghue/burnrate/compare/v0.3.0...v0.4.0) (2026-09-14)


### Features

* detect Claude account switches and rebase alert state ([46dc4c9](https://github.com/RichardODonoghue/burnrate/commit/46dc4c988678a049cba23b706023ccd7c39987a2))
* detect Claude account switches and rebase alert state ([79a7f01](https://github.com/RichardODonoghue/burnrate/commit/79a7f01c83a6387d701d5b9df17926487d38fb86))

## [0.3.0](https://github.com/RichardODonoghue/burnrate/compare/v0.2.0...v0.3.0) (2026-09-13)


### Features

* check GitHub releases for updates and self-install them ([a1478a4](https://github.com/RichardODonoghue/burnrate/commit/a1478a4f3557a1dba243b5dd44c3a6360bbc6212))
* check GitHub releases for updates and self-install them ([fe16616](https://github.com/RichardODonoghue/burnrate/commit/fe1661608e9b3e4346c0c239608d8557f3161f0f))
* tooltips for the daily usage and top-models bar charts ([9c8720d](https://github.com/RichardODonoghue/burnrate/commit/9c8720d652ca05ce2e799a9033e9150d67215860))
* tooltips for the daily usage and top-models bar charts ([ef651c8](https://github.com/RichardODonoghue/burnrate/commit/ef651c8f93d04360e9e2742b085a1f18a1b2c22b))


### Bug Fixes

* attach zip + dmg to releases ([523a9cc](https://github.com/RichardODonoghue/burnrate/commit/523a9ccc02115f9d8140af5d1c6861c0aca0e1f0))
* attach zip + dmg to releases (release-please tags don't trigger workflows) ([5d00fd8](https://github.com/RichardODonoghue/burnrate/commit/5d00fd8aa0e86c4fe2993af0cc9343896848d91a))
* capture OpenCode reasoning tokens; tag Go vs Zen; drop Claude &lt;synthetic&gt; ([3251723](https://github.com/RichardODonoghue/burnrate/commit/3251723483ea529318bc3453ba6e2cbdf46feeab))
* OpenCode reasoning tokens, Go/Zen tags, and Claude &lt;synthetic&gt; rows ([0c4a3cc](https://github.com/RichardODonoghue/burnrate/commit/0c4a3cc5eb43061ec1a1020ee5ccae2d29cc69d4))
* usage cards honor the provider filter ([7e83cbd](https://github.com/RichardODonoghue/burnrate/commit/7e83cbdce678f67cb7030a0eb020864deb2decf6))
* usage cards honor the provider filter ([93b83d5](https://github.com/RichardODonoghue/burnrate/commit/93b83d528ca529babb3895be72c82510f95b3ca8))

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
