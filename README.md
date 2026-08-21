# ReorderingMenus

KOReader plugin to reorder, hide, and customize menus in Book and File Manager views.

Uses native `SortWidget` — drag to reorder, checkbox to hide, double-tap/hold to drill into submenus.

## Install
```bash
PLUGIN_DIR=/path/to/ReorderingMenus
PLUGIN_DEST="$HOME/Library/Application Support/koreader/plugins/reorderingmenus.koplugin"
mkdir -p "$PLUGIN_DEST"
cp "$PLUGIN_DIR"/{_meta.lua,main.lua,menu_titles.lua,menuorder_manager.lua,ui_screens.lua} "$PLUGIN_DEST/"
# restart KOReader
```

## Use
`Tools → More tools → Reorder menus` (tap to mark; double-tap a marked submenu to edit it)

## Dev
```bash
PLUGIN_DIR=/path/to/ReorderingMenus
cd /Applications/KOReader.app/Contents/koreader
KO_HOME="$HOME/Library/Application Support/koreader" \
  DYLD_LIBRARY_PATH=./libs \
  ./luajit "$PLUGIN_DIR/tests/test_reordering.lua"
```
