# ReorderingMenus

KOReader plugin to reorder, hide, and customize menus in Book and File Manager views.

Uses native `SortWidget` — drag to reorder, checkbox to hide, double-tap/hold to drill into submenus.

## Install

1. Download the latest `reorderingmenus.koplugin.zip` from the [Releases](https://github.com/nraikm/ReorderingMenus/releases) page.
2. Unpack it.
3. Move the `reorderingmenus.koplugin` folder into your KOReader plugins directory and restart KOReader.

## Use

`Tools → More tools → Reorder menus`

- Tap to mark/move, checkbox to hide/show (hidden appear dimmed at bottom).
- Double-tap a marked submenu or long-press → **Edit submenu** to drill down.
- Hamburger menu: separators, sort, presets, search, reset.

## Dev

```bash
cd /Applications/KOReader.app/Contents/koreader
KO_HOME=~/Library/Application\ Support/koreader DYLD_LIBRARY_PATH=./libs ./luajit ~/Development/ReorderingMenus/tests/test_reordering.lua
```
