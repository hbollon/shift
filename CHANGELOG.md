# Changelog

All notable changes to Shift. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [1.0.1](https://github.com/hbollon/shift/releases/tag/v1.0.1) - 2026-10-24

### Bug fixes

- Declare gdbus and loginctl as optional dependencies ([c8f8479](https://github.com/hbollon/shift/commit/c8f8479dc06b72907ef838d8fa291b18809d2761))


## [1.0.0](https://github.com/hbollon/shift/releases/tag/v1.0.0) - 2026-10-24

### Features

- Scaffold plugin manifest and entries ([336e797](https://github.com/hbollon/shift/commit/336e79714a6d0e1988f0420502a0784513dc2d57))
- Add core service with manual check in/out, persistence and IPC ([474eaa8](https://github.com/hbollon/shift/commit/474eaa8d865802fe18bb54eee1bfa7889fa197fd))
- Show live worked time in bar widget with right-click check in/out ([a751cce](https://github.com/hbollon/shift/commit/a751ccebf1932214525fe7e5370b36e063d4237d))
- Add undo, onboarding state and today's sessions to the core service ([331a19c](https://github.com/hbollon/shift/commit/331a19c617e5155b4ba728e7d365c9c4c486e53f))
- Show progress ring and display styles in bar widget ([d0680aa](https://github.com/hbollon/shift/commit/d0680aa9af6ac9893383b37f6b9fa1ef5d92b7c2))
- Add dashboard panel with live hero, stats and today's sessions ([3afb894](https://github.com/hbollon/shift/commit/3afb89484602847f1b2179c6fe8638e05feb32b0))
- Toggle tracking from control-center tile ([150458b](https://github.com/hbollon/shift/commit/150458b007e25d785ccc5d3e208eb0cabd39784d))
- Add automation with work-hours window, absence tracking and workday rollover ([4437694](https://github.com/hbollon/shift/commit/4437694670ee624add344b104f0cc427c7df345c))
- Split sessions around removed absences ([fd6d784](https://github.com/hbollon/shift/commit/fd6d7846225545e28688b901bd8fbf286ed7adb9))
- Fetch public holidays per country with an offline cache ([e169162](https://github.com/hbollon/shift/commit/e169162f9e15e85359df5f13ae2cb1fa52b3068c))
- Add contract history, settled balance, adjustments and days off ([203d3ed](https://github.com/hbollon/shift/commit/203d3ed4ebacb13d042a67cc2c7e288dea24f51b))
- Add history views, day editor and balance tab to the dashboard ([f1da59d](https://github.com/hbollon/shift/commit/f1da59d2f962a330e42583b2771c77a3c0e3141d))
- Back up data files every workday with daily and monthly retention ([df5a66e](https://github.com/hbollon/shift/commit/df5a66e6b52518510393a81ed9a22faa85d2e43b))
- Restore damaged files from backups and migrate older schemas after a backup ([b10324d](https://github.com/hbollon/shift/commit/b10324d451ae54bf68e16790cd6eabf57d00c928))
- Notify when the daily target is reached, an absence needs review or a check-in is suggested ([2be6e59](https://github.com/hbollon/shift/commit/2be6e5940b69081aff850d999426ad39f3803c12))

### Bug fixes

- Fit the hero counter inside the ring for every duration format ([b0923da](https://github.com/hbollon/shift/commit/b0923da6abe365a63a9bf32b13fa6f1beb6a7bac))
- Align hero counter units and seconds on the numbers' baseline ([50231ae](https://github.com/hbollon/shift/commit/50231ae2e23457fa5bc40a7d20df1b58d360bd81))
- Shorten notification texts, add missing tooltips and raise small text to 12 px ([682a8f5](https://github.com/hbollon/shift/commit/682a8f5a7baf24720350654a55b337d4903279c2))

### Performance

- Build the window preview per day and only when days off or holidays change ([6e8814e](https://github.com/hbollon/shift/commit/6e8814ebc703073be2f0af255a0896ec5145804a))
- Lighten dashboard renders with a structure counter and cached dates ([0dd31f5](https://github.com/hbollon/shift/commit/0dd31f5df0d4b0fb2528e6519417cff272d82c4e))
- Keep the settled balance by month and spread its first pass over ticks ([b1b6fa0](https://github.com/hbollon/shift/commit/b1b6fa085e720d768aa88d89589f2793ba020d00))

