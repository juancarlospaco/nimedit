## See the file 'themedesc.nim' to see what is theme-able (everything).
import themedesc

theme.editorFont = "DejaVuSansMono"
theme.editorFontSize = 15
theme.uiFont = "Arial"
theme.uiFontSize = 12
theme.uiXGap = 5
theme.uiYGap = 5

theme.uiActiveElement = 0xFFA500
theme.uiInactiveElement = 0xC0C0C0
theme.background = 0x292929
const foreground = 0xfafafa
theme.foreground = foreground
theme.cursor = foreground

theme.selected = 0x1d1d1d
theme.highlighted = 0x0c090a


# If the width of the window exceeds this value, a console is activated:
theme.consoleAfter = 900
#theme.consoleWidth = %50

template ss(key, val; style = FontStyle.Normal) =
  tokens[TokenClass.key] = (val, style)

const
  White = 0xffffff
  Orange = 0xFFA500
  Blue = 0x00FFFF
  Red = 0xFF0000
  Yellow = 0xFFFF00
  Pink = 0xFF00FF
  Gray = 0x808080
  Green = 0x44FF44
  Deeppink = 0xFF1493

ss None, White
ss Whitespace, White
ss DecNumber, Blue
ss BinNumber, Blue
ss HexNumber, Blue
ss OctNumber, Blue
ss FloatNumber, Blue
ss Identifier, White
ss Keyword, White, FontStyle.Bold
ss StringLit, Orange
ss LongStringLit, Orange
ss CharLit, Orange
ss EscapeSequence, Gray
ss Operator, White
ss Punctuation, White
ss Comment, Green, FontStyle.Italic
ss LongComment, DeepPink
ss RegularExpression, Pink
ss TagStart, Yellow
ss TagEnd, Yellow
ss Key, White
ss Value, Blue
ss RawData, Pink
ss Assembler, Pink
ss Preprocessor, Yellow
ss Directive, Yellow
ss Command, Yellow
ss Rule, Yellow
ss Link, Blue, FontStyle.Bold
ss Label, Blue
ss Reference, Blue
ss Other, White
ss Red, Red
ss Green, Green
ss Yellow, Yellow