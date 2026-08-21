# ReorderingMenus

KOReader plugin to reorder, hide, and customize menus in Book and File Manager views.

Uses native `SortWidget` — drag to reorder, checkbox to hide, double-tap/hold to drill into submenus.

## Install
```bash
cp -r reorderingmenus.koplugin ~/Library/Application\ Support/koreader/plugins/
# restart KOReader
```

## Use
`Tools → More tools → Reorder menus` → `Reorder menus` (tap to mark, double-tap marked submenu to edit)

## Dev
```bash
cd /Applications/KOReader.app/Contents/koreader
KO_HOME=~/Library/Application\ Support/koreader DYLD_LIBRARY_PATH=./libs ./luajit ~/Development/ReorderingMenus/tests/test_reordering.lua
```
