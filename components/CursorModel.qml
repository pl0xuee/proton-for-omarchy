import QtQuick

// Keyboard cursor over rows of focus targets. `rows` is an array of arrays
// of string ids (one inner array per visual row; several ids = a horizontal
// group such as a chip row). j/k moves between rows, h/l within a row.
// Items compare `cursor.has(myId)` for their highlight.
QtObject {
  id: root

  property var rows: []
  property int row: 0
  property int col: 0
  property bool active: false
  readonly property string currentId: {
    if (rows.length === 0) return ""
    var r = rows[Math.max(0, Math.min(row, rows.length - 1))] || []
    if (r.length === 0) return ""
    return String(r[Math.max(0, Math.min(col, r.length - 1))])
  }

  signal moved()

  function clamp() {
    if (rows.length === 0) { row = 0; col = 0; return }
    row = Math.max(0, Math.min(row, rows.length - 1))
    var r = rows[row] || []
    col = Math.max(0, Math.min(col, Math.max(0, r.length - 1)))
  }

  // Returns false when the move would leave the top edge (caller may hand
  // focus to the tab bar / search field).
  function move(dx, dy) {
    if (rows.length === 0) return false
    if (!active) { active = true; clamp(); moved(); return true }
    if (dy < 0 && row === 0) return false
    if (dy !== 0) {
      row = Math.max(0, Math.min(rows.length - 1, row + dy))
      var r = rows[row] || []
      col = Math.min(col, Math.max(0, r.length - 1))
    }
    if (dx !== 0) {
      var cur = rows[row] || []
      if (cur.length <= 1) return false
      col = Math.max(0, Math.min(cur.length - 1, col + dx))
    }
    moved()
    return true
  }

  function setId(targetId) {
    for (var r = 0; r < rows.length; r++) {
      var items = rows[r] || []
      for (var c = 0; c < items.length; c++) {
        if (String(items[c]) === String(targetId)) {
          row = r
          col = c
          active = true
          return true
        }
      }
    }
    return false
  }

  function reset() {
    row = 0
    col = 0
    active = false
  }

  function has(targetId) {
    return active && currentId === String(targetId)
  }

  // Keep the cursor on the same target when rows are rebuilt, if possible.
  onRowsChanged: {
    var keep = _last
    if (keep !== "" && setIdQuiet(keep)) return
    clamp()
  }
  onCurrentIdChanged: if (currentId !== "") _last = currentId
  property string _last: ""

  function setIdQuiet(targetId) {
    for (var r = 0; r < rows.length; r++) {
      var items = rows[r] || []
      for (var c = 0; c < items.length; c++) {
        if (String(items[c]) === String(targetId)) { row = r; col = c; return true }
      }
    }
    return false
  }
}
