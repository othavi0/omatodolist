import QtQuick
import qs.Commons
import qs.Ui

// The button used everywhere in the panel (New, save/discard/delete/copy,
// EmptyState's New note/New todo). Pinned to Style.spacing.controlHeight:
// the kit's Button sizes to content, and Style.font.icon (14px) is taller
// than Style.font.body (12px), so an icon+text button would otherwise grow
// past a plain text button.
Button {
    implicitHeight: Style.spacing.controlHeight
    iconSize: Style.font.body + 2
}
