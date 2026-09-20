#!/usr/bin/env bash
# Drives the real MainTab against a seeded sqlite db, offscreen, then asserts
# on the rows that reached the db. Covers the editor's save-on-leave contract.

set -euo pipefail
source "$(dirname "$0")/lib/harness.sh"

cat > "$cfg_dir/shell.qml" <<'QML'
import QtQuick
import Quickshell
import qs.Commons
import "data" as Data
import "ui" as Ui

ShellRoot {
  id: sr
  property int stepIndex: 0
  property bool started: false
  readonly property var steps: [
    function() { mainTab.pickItem(2); mainTab.focusEditor() },
    function() { mainTab.editorTitle = "EDITED-RENEW"; mainTab.pickItem(3) },
    function() { mainTab.commitIfDirty() },
    function() { console.log("HIGHLIGHTED " + sr.highlighted(mainTab).join(",")) },

    function() { mainTab.pickItem(4); mainTab.focusEditor() },
    function() { mainTab.editorTitle = "EDITED-COFFEE"; mainTab.focusSearch() },
    function() { mainTab.searchText = "panel" },
    function() { mainTab.searchText = "" },

    function() { mainTab.startNew("note") },
    function() { mainTab.editorTitle = "DRAFT-ON-CLOSE"; mainTab.commitIfDirty() },

    function() { mainTab.pickItem(1); mainTab.focusEditor() },
    function() { mainTab.editorTitle = "DISCARDED"; mainTab.discardEditor() },
    function() { mainTab.commitIfDirty() },

    function() { mainTab.pickItem(5); mainTab.convertSelected() }
  ]

  function highlighted(item) {
    var ids = []
    if (String(item).indexOf("ItemRow") === 0 && item.selected) ids.push(item.item.id)
    for (var i = 0; i < item.children.length; ++i) ids = ids.concat(sr.highlighted(item.children[i]))
    return ids
  }

  Data.Db {
    id: db
    Component.onCompleted: db.init()
  }
  Connections {
    target: db
    function onItemsUpdated() { if (!sr.started) { sr.started = true; stepTimer.start() } }
  }
  Timer {
    id: stepTimer
    interval: 600
    repeat: true
    onTriggered: {
      if (sr.stepIndex >= sr.steps.length) { Qt.exit(0); return }
      sr.steps[sr.stepIndex++]()
    }
  }
  FloatingWindow {
    implicitWidth: 760; implicitHeight: 520
    Ui.MainTab { id: mainTab; anchors.fill: parent; db: db }
  }
}
QML

run_qs > "$cfg_dir/qs.log" 2>&1 || { cat "$cfg_dir/qs.log"; echo "qs exited non-zero"; exit 2; }

failures=0
expect() {
  local what="$1" sql="$2" want="$3" got
  got="$(sqlite3 "$db" "$sql")"
  if [[ "$got" == "$want" ]]; then echo "ok   $what"
  else echo "FAIL $what: want '$want', got '$got'"; failures=$((failures + 1)); fi
}

expect "edit is saved to the item it was typed in when another row is clicked" \
  "SELECT title FROM items WHERE id = 2" "EDITED-RENEW"
expect "the clicked row keeps its own title" \
  "SELECT title FROM items WHERE id = 3" "Reply to upstream PR review"
if rg -q "HIGHLIGHTED 3$" "$cfg_dir/qs.log"; then echo "ok   only the clicked row is highlighted after the save reloads the list"
else echo "FAIL highlight after reload: $(rg -o 'HIGHLIGHTED.*' "$cfg_dir/qs.log" || echo none)"; failures=$((failures + 1)); fi
expect "edit is saved when focus moves to the search field" \
  "SELECT title FROM items WHERE id = 4" "EDITED-COFFEE"
expect "draft is saved when the panel closes" \
  "SELECT COUNT(*) FROM items WHERE title = 'DRAFT-ON-CLOSE'" "1"
expect "discard leaves the item untouched" \
  "SELECT title FROM items WHERE id = 1" "Ideas for the panel"
expect "convert flips the type and keeps the status" \
  "SELECT type || ':' || status FROM items WHERE id = 5" "note:1"
expect "convert is logged in history" \
  "SELECT COUNT(*) FROM history WHERE action = 'converted' AND title = 'Backup scratchpad.db'" "1"

exit $(( failures > 0 ))
