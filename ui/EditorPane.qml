import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Item.js" as ItemJs
import "Icons.js" as Icons

// Right-hand detail/editor pane: the selected item, or a new-item draft.
// Owns the title/body fields and their in-pane key routing; selection,
// dirty-base tracking, db calls and toasts stay in MainTab — this
// component only shows state and emits what the user asked for.
ColumnLayout {
  id: root

  property var item: null
  property bool draft: false
  property string draftType: "note"
  property bool dirty: false              // existing item's fields differ from its saved base
  property bool deleteArmed: false
  property int nowSeconds: 0
  property color foreground: Color.foreground
  property color accent: Color.accent

  property alias titleText: titleField.text
  property alias bodyText: bodyField.text
  readonly property int bodyWrapMode: bodyField.wrapMode
  readonly property bool titleFocused: titleField.activeFocus
  readonly property bool bodyFocused: bodyField.activeFocus
  readonly property bool unsaved: root.draft || root.dirty

  signal leaveRequested()               // Esc/Backtab from title, Esc/Tab/Enter from body — autosave and back to the list
  signal toggleDraftTypeRequested(string v)
  signal toggleRequested()
  signal convertRequested()
  signal copyRequested()
  signal deleteClicked()
  signal saveRequested()
  signal discardRequested()

  function focusTitle() { titleField.forceActiveFocus() }
  function focusBody() { bodyField.forceActiveFocus() }

  spacing: Style.spacing.lg

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.spacing.lg

    Segment {
      visible: root.draft
      fill: false
      options: [
        { value: "note", label: "Note", icon: Icons.note },
        { value: "todo", label: "Todo", icon: Icons.boxOff }
      ]
      value: root.draftType
      foreground: root.foreground
      accent: root.accent
      onPicked: function(v) { root.toggleDraftTypeRequested(v) }
    }

    Row {
      visible: !root.draft
      spacing: Style.spacing.md

      Text {
        text: root.item && ItemJs.isTodo(root.item) ? Icons.boxOff : Icons.note
        color: root.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.icon
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: root.item && ItemJs.isTodo(root.item) ? "Todo" : "Note"
        color: root.foreground
        font.bold: true
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: statusText.implicitWidth + Style.space(14)
        height: statusText.implicitHeight + Style.space(6)
        radius: height / 2
        color: root.item && ItemJs.isDone(root.item) ? Util.alpha(root.foreground, 0.08) : Util.alpha(Color.urgent, 0.14)
        Text {
          id: statusText
          anchors.centerIn: parent
          text: root.item ? ItemJs.statusLabel(root.item) : ""
          color: root.item && ItemJs.isDone(root.item) ? Util.alpha(root.foreground, 0.7) : Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    Item { Layout.fillWidth: true }

    Row {
      spacing: Style.spacing.sm
      Rectangle {
        width: Style.space(6); height: width; radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: root.unsaved ? Color.urgent : Util.alpha(root.foreground, 0.4)
      }
      Text {
        text: root.draft
          ? "Unsaved draft"
          : (root.dirty
              ? "Unsaved changes"
              : "Saved · edited " + ItemJs.relativeAge(Number(root.item ? root.item.updated_at : 0), root.nowSeconds))
        color: Util.alpha(root.foreground, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  Field {
    id: titleField
    Layout.fillWidth: true
    placeholderText: root.draft ? (root.draftType === "todo" ? "What needs doing?" : "Note title") : "Title"
    foreground: root.foreground
    accent: root.accent
    activeFocusOnTab: false
    onAccepted: root.focusBody()
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Tab) {
        root.focusBody(); event.accepted = true
      } else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Escape) {
        root.leaveRequested(); event.accepted = true
      } else if (event.text === "t" && root.draft
        && String(titleField.text) === "" && !event.modifiers) {
        root.toggleDraftTypeRequested(root.draftType === "todo" ? "note" : "todo"); event.accepted = true
      }
    }
  }

  Rectangle {
    Layout.fillWidth: true
    height: 1
    color: Util.alpha(root.foreground, 0.10)
  }

  QQC.TextArea {
    id: bodyField
    Layout.fillWidth: true
    Layout.fillHeight: true
    placeholderText: "Details (optional)"
    color: root.foreground
    placeholderTextColor: Util.alpha(root.foreground, 0.45)
    selectionColor: Style.selectionFillFor(root.foreground, root.accent)
    selectedTextColor: root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    wrapMode: Text.Wrap
    padding: Style.spacing.controlPaddingX
    background: Rectangle { color: "transparent" }
    selectByMouse: true
    activeFocusOnTab: false
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (!(event.modifiers & Qt.ShiftModifier)) { root.leaveRequested(); event.accepted = true }
        else event.accepted = false          // let Shift+Enter insert a newline
      } else if (event.key === Qt.Key_Tab) {
        root.leaveRequested(); event.accepted = true
      } else if (event.key === Qt.Key_Backtab) {
        Qt.callLater(function() { root.focusTitle() }); event.accepted = true
      } else if (event.key === Qt.Key_Escape) {
        root.leaveRequested(); event.accepted = true
      }
    }
  }

  RowLayout {
    Layout.fillWidth: true
    visible: !root.unsaved
    spacing: Style.spacing.md

    ActionButton {
      bordered: true
      iconText: Icons.check
      text: root.item ? ItemJs.toggleVerb(root.item) : ""
      foreground: root.foreground
      accent: root.accent
      onClicked: root.toggleRequested()
    }
    ActionButton {
      bordered: true
      iconText: Icons.swap
      text: root.item && ItemJs.isTodo(root.item) ? "To note" : "To todo"
      foreground: root.foreground
      accent: root.accent
      onClicked: root.convertRequested()
    }
    ActionButton {
      bordered: true
      iconText: Icons.copy
      text: "Copy"
      foreground: root.foreground
      accent: root.accent
      onClicked: root.copyRequested()
    }
    Item { Layout.fillWidth: true }
    ActionButton {
      bordered: true
      iconText: Icons.trash
      text: root.deleteArmed ? "Confirm delete" : "Delete"
      foreground: Color.urgent
      onClicked: root.deleteClicked()
    }
  }

  RowLayout {
    Layout.fillWidth: true
    visible: root.unsaved
    spacing: Style.spacing.md

    ActionButton {
      bordered: true
      selected: true
      iconText: Icons.check
      text: root.draft ? ("Save " + root.draftType) : "Save"
      foreground: root.foreground
      accent: root.accent
      onClicked: root.saveRequested()
    }
    ActionButton {
      bordered: true
      text: "Discard"
      foreground: root.foreground
      accent: root.accent
      onClicked: root.discardRequested()
    }
    Item { Layout.fillWidth: true }
    ActionButton {
      visible: !root.draft
      bordered: true
      iconText: Icons.trash
      text: root.deleteArmed ? "Confirm delete" : "Delete"
      foreground: Color.urgent
      onClicked: root.deleteClicked()
    }
  }
}
