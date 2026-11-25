import QtQuick
import qs.Commons

// Every dynamic string in the plugin renders through this: PlainText format
// means server names, cities, account names or error messages can never be
// interpreted as markup.
Text {
  textFormat: Text.PlainText
  elide: Text.ElideRight
  font.family: Style.font.family
  font.pixelSize: Style.font.body
  verticalAlignment: Text.AlignVCenter
  maximumLineCount: wrapMode === Text.NoWrap ? 1 : 4
}
