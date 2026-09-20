pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Item.js" as ItemJs

// "Items" tab: unified list on the left (search + All/Notes/Todos segment,
// pending-first then recency), and the right-hand pane that doubles as the
// inline editor — no overlay composer. Selecting a row shows its title+body
// as editable fields; `n` starts a new-item draft; Tab/Enter move into the
// pane. The Toast is owned by Panel.qml and injected here (components in
// this "ui" directory reference each other by type name, same as this
// plugin author's agent-bar).
//
// Keyboard map (preserved):
//   list:   j/k or ↑/↓ move · Enter/l/→/Tab edit the selected item
//           · n new draft · space/c toggle status · d delete (double-press
//           to confirm) · / focus search · Esc closes the panel
//   editor: fields own printable keys · Tab title→body, body→save+list
//           · Enter in body saves · Esc saves (auto-save on leaving)
//           · `t` on an empty draft title toggles note/todo
//   search: Esc/Shift+Tab return to the list
Item {
    id: root

    // ------------------------------------------------------------------ deps
    property QtObject db: null              // Panel's Data.Db instance
    property var toast: null                // ui/Toast instance (Panel-owned)
    property color foreground: Color.foreground
    property color accent: Color.accent

    signal closeRequested()                 // Esc in the list closes the panel

    // ------------------------------------------------------------------ state
    property string filterType: "all"       // all | note | todo
    property int selectedId: -1
    property bool draftNew: false           // right pane holds a new-item draft
    property string draftType: "note"       // draft's type ('note' | 'todo')
    property int deleteArmId: -1            // -1 = not armed (shared: list `d d` + editor Delete)
    property int nowSeconds: Math.floor(Date.now() / 1000)

    readonly property bool deleteArmed: root.deleteArmId >= 0
    property alias searchText: searchField.text   // settable: also lets callers (tests) type a query

    // Values the editor opened with, so commit only writes when something
    // actually changed (keeps "edited" history rows honest).
    property string _editBaseTitle: ""
    property string _editBaseBody: ""

    // Test/compat hooks: forward through EditorPane/EmptyState now that the
    // editor and empty states live in their own components.
    property alias editorTitle: editorPane.titleText
    property alias editorBody: editorPane.bodyText
    readonly property int bodyWrapMode: editorPane.bodyWrapMode
    readonly property bool editingNow: editorPane.titleFocused || editorPane.bodyFocused
    readonly property string emptyLabel: (root.itemList.length === 0 && !root.draftNew)
        ? (root._filtered ? "No matches" : "Nothing here yet")
        : ""

    // Focus derived from real focus, not a magic int: search/list/editor/draft.
    readonly property string focusContext: {
        if (searchField.activeFocus) return "search"
        if (editorPane.titleFocused || editorPane.bodyFocused) return root.draftNew ? "draft" : "editor"
        return "list"
    }

    readonly property var hintSets: ({
        list: [["j/k", "move"], ["Enter", "edit"], ["n", "new"], ["Space", "toggle"],
            ["d d", "delete"], ["/", "search"], ["Esc", "close"]],
        search: [["Enter", "to list"], ["Esc", "clear"]],
        editor: [["Tab", "next field"], ["Enter", "save"], ["Shift+Enter", "new line"], ["Esc", "save and back"]],
        draft: [["Tab", "next field"], ["Enter", "save"], ["Shift+Enter", "new line"], ["Esc", "save and back"], ["t", "note/todo"]],
        deleteArmed: [["d", "press again to delete"]]
    })
    readonly property var hints: root.deleteArmed ? root.hintSets.deleteArmed : root.hintSets[root.focusContext]

    // Highlighting a different row (j/k/click) refreshes the right-hand
    // pane to the newly selected item — but never clobbers a draft or an
    // in-progress edit.
    onSelectedIdChanged: {
        if (root.draftNew || editorPane.titleFocused || editorPane.bodyFocused) return
        root.refillEditor()
    }

    // ------------------------------------------------------------------ derived
    function indexOfId(items, id) {
        var list = items || []
        for (var i = 0; i < list.length; ++i)
            if (Number(list[i].id) === Number(id)) return i
        return -1
    }
    readonly property var itemList: root.db ? (root.db.items || []) : []
    readonly property int selectedIndex: root.indexOfId(root.itemList, root.selectedId)
    readonly property var selectedItem: root.selectedIndex >= 0 ? root.itemList[root.selectedIndex] : null
    readonly property bool _filtered: root.filterType !== "all" || root.searchText.trim() !== ""
    readonly property bool editorDirty: !root.draftNew && !!root.selectedItem
        && (editorPane.titleText !== root._editBaseTitle || editorPane.bodyText !== root._editBaseBody)

    // ------------------------------------------------------------------ actions
    function toggleStatus() {
        if (!root.db || !root.selectedItem) return
        root.db.setStatus(root.selectedItem.id, ItemJs.isDone(root.selectedItem) ? 0 : 1)
    }
    function convertSelected() {
        if (!root.db || !root.selectedItem) return
        root.db.convertType(root.selectedItem.id)
    }
    function copySelected() {
        if (!root.selectedItem) return
        var title = String(root.selectedItem.title || "")
        var body = String(root.selectedItem.body || "")
        Quickshell.clipboardText = body === "" ? title : (title + "\n\n" + body)
        if (root.toast) root.toast.show("Copied")
    }
    function armDelete() {
        if (!root.db || !root.selectedItem) return
        if (root.deleteArmed && root.deleteArmId === root.selectedItem.id) {
            root.deleteArmId = -1
            deleteArmTimer.stop()
            root.db.deleteItem(root.selectedItem.id)
            return
        }
        root.deleteArmId = root.selectedItem.id
        deleteArmTimer.restart()
        if (root.toast) root.toast.show("Deleting — press d again to confirm")
    }

    // ------------------------------------------------------------------ focus
    function focusSearch() { searchField.forceActiveFocus() }
    function focusList() { pump.forceActiveFocus() }

    // Called by Panel.qml when the panel opens or this tab is re-shown.
    function resetFocus() {
        root.draftNew = false
        root.refillEditor()
        root.focusList()
    }

    // ------------------------------------------------------------------ navigation
    function moveSelection(delta) {
        var items = root.itemList
        var n = items.length
        if (n === 0) return
        var cur = root.selectedIndex
        var next = Math.max(0, Math.min(n - 1, cur + delta))
        root.selectedId = items[next].id
        listView.positionViewAtIndex(next, ListView.Center)
    }

    // ------------------------------------------------------------------ editor
    // Sync the editor fields to the selected item (used on reset, after data
    // reloads, and when a draft/edit is discarded). Resolved directly from
    // selectedId + itemList rather than the selectedItem binding, which can
    // lag by one step inside onSelectedIdChanged.
    function refillEditor() {
        var idx = root.indexOfId(root.itemList, root.selectedId)
        var it = idx >= 0 ? root.itemList[idx] : null
        editorPane.titleText = it ? String(it.title || "") : ""
        editorPane.bodyText = it ? String(it.body || "") : ""
        root._editBaseTitle = editorPane.titleText
        root._editBaseBody = editorPane.bodyText
    }

    // Enter/Tab/l from the list: open the selected item in the editor.
    function focusEditor() {
        root.deleteArmId = -1
        deleteArmTimer.stop()
        if (root.draftNew) { Qt.callLater(function() { editorPane.focusTitle() }); return }
        if (!root.selectedItem) { root.startNew("note"); return }
        root.draftNew = false
        root.refillEditor()
        Qt.callLater(function() { editorPane.focusTitle() })
    }

    // `n`/`a` from the list, or EmptyState's New note/New todo: start a
    // new-item draft of the given type.
    function startNew(type) {
        if (!root.db) return
        root.deleteArmId = -1
        deleteArmTimer.stop()
        root.draftNew = true
        root.draftType = type === "todo" ? "todo" : "note"
        editorPane.titleText = ""
        editorPane.bodyText = ""
        Qt.callLater(function() { editorPane.focusTitle() })
    }

    // Auto-save on leaving the editor: Tab from the body, Enter in the body,
    // or Esc/Backtab from any field all land here — same trigger points as
    // the editor's explicit Save button. Empty new drafts are discarded.
    function commitEditor() {
        var title = String(editorPane.titleText || "").trim()
        var body = String(editorPane.bodyText || "")

        if (root.draftNew) {
            root.draftNew = false
            if (title === "") {
                if (root.toast) root.toast.show("New item needs a title")
                root.refillEditor()
            } else {
                root.db.add(root.draftType, title, body)
                if (root.toast) root.toast.show("Added " + root.draftType + " — " + title)
            }
            root.focusList()
            return
        }

        if (!root.selectedItem) {
            root.refillEditor()
            root.focusList()
            return
        }
        if (title === "") {
            if (root.toast) root.toast.show("Title can't be empty")
            return
        }
        if (title !== root._editBaseTitle || body !== root._editBaseBody) {
            root.db.update(root.selectedItem.id, title, body)
            if (root.toast) root.toast.show("Saved — " + title)
        }
        root.focusList()
    }

    // Discard: an existing item reloads its fields from the saved base; a
    // draft is simply abandoned. Both converge on the same refill.
    function discardEditor() {
        root.draftNew = false
        root.refillEditor()
        root.focusList()
    }

    // Dirtiness is read off the fields rather than focus: closing the panel
    // releases keyboard focus before this function runs.
    function commitIfDirty() {
        if (root.draftNew || root.editorDirty) root.commitEditor()
    }

    // ------------------------------------------------------------------ keys
    function onListKey(event) {
        if (event.key === Qt.Key_Down || event.key === Qt.Key_J || event.text === "j") {
            root.moveSelection(1); event.accepted = true
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K || event.text === "k") {
            root.moveSelection(-1); event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Right || event.key === Qt.Key_Tab
            || event.key === Qt.Key_L || event.text === "l") {
            root.focusEditor(); event.accepted = true
        } else if (event.key === Qt.Key_Space || event.text === " "
            || event.key === Qt.Key_C || event.text === "c") {
            root.toggleStatus(); event.accepted = true
        } else if (event.text === "d") {
            root.armDelete(); event.accepted = true
        } else if (event.text === "n" || event.text === "a") {
            root.startNew("note"); event.accepted = true
        } else if (event.text === "/") {
            root.focusSearch(); event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
            if (root.deleteArmed) { root.deleteArmId = -1; deleteArmTimer.stop(); event.accepted = true }
            else { root.closeRequested(); event.accepted = true }
        }
    }

    // ------------------------------------------------------------------ focus owner
    Item {
        id: pump
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) { root.onListKey(event) }
    }

    // ------------------------------------------------------------------ search debounce
    Timer {
        id: filterDebounce
        interval: 120
        onTriggered: {
            if (root.db) root.db.list(root.filterType, root.searchText)
        }
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.nowSeconds = Math.floor(Date.now() / 1000)
    }

    // ------------------------------------------------------------------ layout
    ColumnLayout {
        anchors.fill: parent
        spacing: Style.spacing.xxl

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.spacing.xxl

            // -------- left: search + filter + list ------------------------
            ColumnLayout {
                Layout.preferredWidth: Style.space(270)
                Layout.maximumWidth: Style.space(270)
                Layout.fillHeight: true
                spacing: Style.spacing.lg

                SearchField {
                    id: searchField
                    Layout.fillWidth: true
                    foreground: root.foreground
                    accent: root.accent
                    activeFocusOnTab: false
                    onTextChanged: filterDebounce.restart()
                    onAccepted: root.focusList()
                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Escape) {
                            searchField.text = ""; root.focusList(); event.accepted = true
                        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                            root.focusList(); event.accepted = true
                        }
                    }
                }

                Segment {
                    id: typeSegment
                    Layout.fillWidth: true
                    value: root.filterType
                    foreground: root.foreground
                    accent: root.accent
                    options: [
                        { value: "all", label: "All", count: root.db ? (root.db.totalNotes + root.db.totalTodos) : 0 },
                        { value: "note", label: "Notes", count: root.db ? root.db.totalNotes : 0 },
                        { value: "todo", label: "Todos", count: root.db ? root.db.totalTodos : 0 }
                    ]
                    onPicked: function(v) { root.filterType = v; filterDebounce.restart() }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    ListView {
                        id: listView
                        anchors.fill: parent
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        keyNavigationEnabled: false
                        spacing: Style.spacing.xxs
                        model: root.itemList
                        currentIndex: root.selectedIndex

                        delegate: ItemRow {
                            required property var modelData
                            required property int index
                            width: listView.width
                            item: modelData
                            selected: index === listView.currentIndex
                            foreground: root.foreground
                            accent: root.accent
                            nowSeconds: root.nowSeconds
                            onPicked: {
                                root.selectedId = modelData.id
                                root.focusList()
                                listView.positionViewAtIndex(index, ListView.Center)
                            }
                            onToggled: {
                                if (root.db) root.db.setStatus(modelData.id, ItemJs.isDone(modelData) ? 0 : 1)
                            }
                        }
                    }

                    EmptyState {
                        anchors.centerIn: parent
                        visible: listView.count === 0
                        filtered: root._filtered
                        foreground: root.foreground
                        accent: root.accent
                        onNewNote: root.startNew("note")
                        onNewTodo: root.startNew("todo")
                        onClearSearch: {
                            searchField.text = ""
                            root.filterType = "all"
                            filterDebounce.restart()
                            root.focusList()
                        }
                    }
                }
            }

            // -------- separator --------------------------------------------
            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                color: Util.alpha(root.foreground, 0.10)
            }

            // -------- right: detail + inline editor -------------------------
            EditorPane {
                id: editorPane
                visible: !!root.selectedItem || root.draftNew
                Layout.fillWidth: true
                Layout.fillHeight: true
                item: root.selectedItem
                draft: root.draftNew
                draftType: root.draftType
                dirty: root.editorDirty
                deleteArmed: root.deleteArmed
                nowSeconds: root.nowSeconds
                foreground: root.foreground
                accent: root.accent
                onLeaveRequested: root.commitEditor()
                onToggleDraftTypeRequested: function(v) { root.draftType = v }
                onToggleRequested: root.toggleStatus()
                onConvertRequested: root.convertSelected()
                onCopyRequested: root.copySelected()
                onDeleteClicked: root.armDelete()
                onSaveRequested: root.commitEditor()
                onDiscardRequested: root.discardEditor()
            }

            Item {
                visible: !root.selectedItem && !root.draftNew
                Layout.fillWidth: true
                Layout.fillHeight: true

                Text {
                    anchors.centerIn: parent
                    text: "Your note or todo opens here."
                    color: Util.alpha(root.foreground, 0.45)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Util.alpha(root.foreground, 0.10)
        }

        HintBar {
            Layout.fillWidth: true
            hints: root.hints
            urgent: root.deleteArmed
            foreground: root.foreground
        }
    }

    Timer {
        id: deleteArmTimer
        interval: 2000
        onTriggered: root.deleteArmId = -1
    }

    // ------------------------------------------------------------------ db sync
    function onItemsSynced() {
        var items = root.itemList
        var refill = !root.draftNew && !editorPane.titleFocused && !editorPane.bodyFocused
        if (root.indexOfId(items, root.selectedId) >= 0) {
            if (refill) root.refillEditor()
            return
        }
        if (items.length === 0) {
            root.selectedId = -1
            root.draftNew = false
            root.refillEditor()
            return
        }
        root.selectedId = items[0].id
        if (refill) root.refillEditor()
        listView.positionViewAtIndex(0, ListView.Center)
    }

    Connections {
        target: root.db
        function onItemsUpdated() { root.onItemsSynced() }
        function onAdded(id) {
            root.selectedId = Number(id)
            Qt.callLater(function() { root.focusList() })
            listView.positionViewAtIndex(root.selectedIndex, ListView.Center)
        }
        function onStatusChanged(id, status) {
            if (Number(id) !== root.selectedId || !root.toast) return
            var item = root.selectedItem
            if (!item) return
            root.toast.show(ItemJs.statusToast(item, status))
        }
        function onTypeChanged(id) {
            var idx = root.indexOfId(root.itemList, Number(id))
            if (idx < 0 || !root.toast) return
            var before = root.itemList[idx]
            var newType = ItemJs.isTodo(before) ? "note" : "todo"
            root.toast.show("Converted to " + newType + " — " + before.title)
        }
        function onItemDeleted(id) {
            if (Number(id) !== root.selectedId) return
            root.deleteArmId = -1
            deleteArmTimer.stop()
            if (root.toast) root.toast.show("Deleted")
            var items = root.itemList
            var idx = root.indexOfId(items, Number(id))
            root.selectedId = (idx >= 0 && idx + 1 < items.length)
                ? items[idx + 1].id
                : (items.length - 1 > 0 ? items[items.length - 1].id : -1)
        }
        function onFailed(message) {
            if (root.toast) root.toast.show("Error: " + String(message || "unknown"), true)
        }
    }

    Component.onCompleted: {
        root.refillEditor()
        root.focusList()
    }
}
