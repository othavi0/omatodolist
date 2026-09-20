.pragma library

// Material Design Icons glyphs (via the Nerd Font patch), by code point —
// never written literally: the write tool strips private-use-area glyphs
// from file contents, so every glyph is built at load time instead.
function g(codePoint) { return String.fromCodePoint(codePoint) }

var plus = g(0xF0415)
var search = g(0xF0349)
var close = g(0xF0156)
var check = g(0xF012C)
var trash = g(0xF0A7A)
var history = g(0xF02DA)
var boxOff = g(0xF0131)
var boxOn = g(0xF0135)
var note = g(0xF11D7)
var copy = g(0xF018F)
var swap = g(0xF04E1)
var all = g(0xF0279)
