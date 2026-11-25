.pragma library

// Depth-first search for the item whose `cursorKey` matches.
function findKey(item, key) {
  if (!item || key === "") return null
  if (item.cursorKey !== undefined && item.cursorKey === key && item.visible) return item
  var kids = item.children || []
  for (var i = 0; i < kids.length; i++) {
    var found = findKey(kids[i], key)
    if (found) return found
  }
  return null
}

// Scroll `flick` the minimum amount so `item` is fully visible.
function ensureVisible(flick, item, margin) {
  if (!flick || !item) return
  var m = margin === undefined ? 6 : margin
  var point = item.mapToItem(flick.contentItem, 0, 0)
  var top = point.y
  var bottom = top + item.height
  var viewTop = flick.contentY
  var viewBottom = viewTop + flick.height
  var maxY = Math.max(0, flick.contentHeight - flick.height)
  if (top < viewTop + m) flick.contentY = Math.max(0, top - m)
  else if (bottom > viewBottom - m) flick.contentY = Math.min(maxY, bottom + m - flick.height)
}
