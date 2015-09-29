# Implementation uses a gap buffer with explicit undo stack.

import strutils, unicode
import styles, highlighters
import sdl2, sdl2/ttf
import buffertype, unihelp, languages
from os import splitFile

const
  tabWidth = 2

include drawbuffer
include finder

proc newBuffer*(heading: string; mgr: ptr StyleManager): Buffer =
  new(result)
  result.front = @[]
  result.back = @[]
  result.filename = ""
  result.heading = heading
  result.actions = @[]
  result.mgr = mgr
  result.readOnly = -1
  result.tabSize = tabWidth
  result.markers = @[]
  result.selected.a = -1
  result.selected.b = -1

proc clear*(result: Buffer) =
  result.front.setLen 0
  result.back.setLen 0
  result.actions.setLen 0
  result.markers.setLen 0
  result.currentLine = 0
  result.firstLine = 0
  result.numberOfLines = 0
  result.desiredCol = 0
  result.cursor = 0
  result.selected.a = -1
  result.selected.b = -1

proc fullText*(b: Buffer): string =
  result = newStringOfCap(b.front.len + b.back.len)
  for i in 0..<b.front.len:
    result.add b.front[i].c
  for i in countdown(b.back.len-1, 0):
    result.add b.back[i].c

template edit(b: Buffer) =
  b.undoIdx = b.actions.len-1

proc prepareForEdit(b: Buffer) =
  if b.cursor < b.front.len:
    for i in countdown(b.front.len-1, b.cursor):
      b.back.add(b.front[i])
    setLen(b.front, b.cursor)
  elif b.cursor > b.front.len:
    let chars = max(b.cursor - b.front.len, 0)
    var took = 0
    for i in countdown(b.back.len-1, max(b.back.len-chars, 0)):
      b.front.add(b.back[i])
      inc took
    setLen(b.back, b.back.len - took)
    #if b.cursor != b.front.len:
    #  echo b.cursor, " ", b.front.len, " ", took
    b.cursor = b.front.len
  assert b.cursor == b.front.len
  b.changed = true

proc upFirstLineOffset(b: Buffer) =
  assert b.firstLineOffset == 0 or b[b.firstLineOffset-1] == '\L'
  assert b.firstLineOffset > 0
  var i = b.firstLineOffset-1
  while i > 0 and b[i-1] != '\L': dec i
  b.firstLineOffset = max(0, i)

proc downFirstLineOffset(b: Buffer) =
  assert b.firstLineOffset == 0 or b[b.firstLineOffset-1] == '\L'
  var i = b.firstLineOffset
  while b[i] != '\L': inc i
  b.firstLineOffset = i+1

proc scroll(b: Buffer; amount: int) =
  assert amount == 1 or amount == -1
  inc b.currentLine, amount
  if b.currentLine < b.firstLine:
    b.firstLine = b.currentLine
    upFirstLineOffset(b)
  elif b.currentLine > b.firstLine + b.span-1:
    inc b.firstLine
    downFirstLineOffset(b)

proc scrollLines*(b: Buffer; amount: int) =
  let oldFirstLine = b.firstLine
  b.firstLine = clamp(b.firstLine+amount, 0, max(0, b.numberOfLines-1))
  # compute the real amount:
  var amount = b.firstLine - oldFirstLine
  if amount < 0:
    while amount < 0:
      upFirstLineOffset(b)
      inc amount
  elif amount > 0:
    while amount > 0:
      downFirstLineOffset(b)
      dec amount
  inc b.firstLine, amount

proc getLine*(b: Buffer): int = b.currentLine
proc getColumn*(b: Buffer): int =
  var i = b.cursor
  while i > 0 and b[i-1] != '\L':
    dec i
  while i < b.cursor and b[i] != '\L':
    i += graphemeLen(b, i)
    inc result

proc getLastLine*(b: Buffer): string =
  var i = b.len
  while i > 0 and b[i-1] != '\L': dec i
  result = ""
  for j in i..<b.len:
    result.add b[j]

proc rawLeft*(b: Buffer) =
  if b.cursor > 0:
    let r = lastRune(b, b.cursor-1)
    if r[0] == Rune('\L'):
      scroll(b, -1)
    b.cursor -= r[1]
    b.desiredCol = getColumn(b)

proc left*(b: Buffer; jump: bool) =
  rawLeft(b)
  if jump:
    while b.cursor > 0 and b[b.cursor] notin WhiteSpace: rawLeft(b)
    while b.cursor > 1 and b[b.cursor-1] in WhiteSpace: rawLeft(b)

proc rawRight(b: Buffer) =
  if b.cursor < b.front.len+b.back.len:
    if b[b.cursor] == '\L':
      scroll(b, 1)
    b.cursor += graphemeLen(b, b.cursor)
    b.desiredCol = getColumn(b)

proc right*(b: Buffer; jump: bool) =
  rawRight(b)
  if jump:
    while b.cursor < b.len and b[b.cursor] in WhiteSpace: rawRight(b)
    while b.cursor < b.len and b[b.cursor] notin WhiteSpace: rawRight(b)

proc up*(b: Buffer; jump: bool) =
  var col = b.desiredCol
  var i = b.cursor

  # move to the *start* of this line
  while i >= 1 and b[i-1] != '\L': dec i
  if i >= 1 and b[i-1] == '\L':
    # move up 1 line:
    dec i
    # move to the *start* of this line
    while i >= 1 and b[i-1] != '\L': dec i
    # move to the desired column:
    while i >= 0 and col > 0 and b[i] != '\L':
      i += graphemeLen(b, i)
      dec col
    scroll(b, -1)
  b.cursor = i
  if b.cursor < 0: b.cursor = 0

proc down*(b: Buffer; jump: bool) =
  var col = b.desiredCol

  let L = b.front.len+b.back.len
  while b.cursor < L:
    if b[b.cursor] == '\L':
      scroll(b, 1)
      break
    b.cursor += 1
  b.cursor += 1

  while b.cursor < L and col > 0:
    if b[b.cursor] == '\L': break
    dec col
    b.cursor += 1
  if b.cursor > L: b.cursor = L
  if b.cursor < 0: b.cursor = 0

proc rawInsert*(b: Buffer; s: string) =
  for i in 0..<s.len:
    case s[i]
    of '\L':
      b.front.add Cell(c: '\L')
      inc b.numberOfLines
      scroll(b, 1)
      inc b.cursor
    of '\C':
      if i < s.len-1 and s[i+1] != '\L':
        b.front.add Cell(c: '\L')
        inc b.numberOfLines
        scroll(b, 1)
        inc b.cursor
    of '\t':
      for i in 1..tabWidth:
        b.front.add Cell(c: ' ')
        inc b.cursor
    of '\0':
      b.front.add Cell(c: '_')
      inc b.cursor
    else:
      b.front.add Cell(c: s[i])
      inc b.cursor

proc loadFromFile*(b: Buffer; filename: string) =
  template detectTabSize() =
    if b.tabSize < 0:
      var j = i+1
      while j < s.len and s[j] == ' ':
        if b.tabSize < 0: b.tabSize = 1
        else: inc b.tabSize
        inc j

  clear(b)
  b.filename = filename
  b.lang = fileExtToLanguage(splitFile(filename).ext)
  let s = readFile(filename)
  # detect tabSize from file:
  b.tabSize = -1
  for i in 0..<s.len:
    case s[i]
    of '\L':
      b.front.add Cell(c: '\L')
      inc b.numberOfLines
      if b.lineending.isNil:
        b.lineending = "\L"
      detectTabSize()
    of '\C':
      if i < s.len-1 and s[i+1] != '\L':
        b.front.add Cell(c: '\L')
        inc b.numberOfLines
        if b.lineending.isNil:
          b.lineending = "\C"
      elif b.lineending.isNil:
        b.lineending = "\C\L"
    of '\t':
      if i > 0 and s[i-1] == ' ': b.tabSize = 8'i8
      b.front.add Cell(c: '\t')
    else:
      b.front.add Cell(c: s[i])
  if b.tabSize < 0: b.tabSize = tabWidth
  highlightEverything(b)

proc save*(b: Buffer) =
  if b.filename.len == 0: b.filename = b.heading
  let f = open(b.filename, fmWrite)
  if b.lineending.isNil or b.lineending.len == 0:
    b.lineending = "\L"
  let L = b.len
  var i = 0
  while i < L:
    let ch = b[i]
    if ch > ' ':
      f.write(ch)
    elif ch == ' ':
      let j = i
      while b[i] == ' ': inc i
      if b[i] == '\L':
        f.write(b.lineending)
      else:
        for ii in j..i-1:
          f.write(' ')
        dec i
    elif ch == '\L':
      f.write(b.lineending)
    else:
      f.write(ch)
    inc(i)
  f.close
  b.changed = false

proc saveAs*(b: Buffer; filename: string) =
  b.filename = filename
  b.lang = fileExtToLanguage(splitFile(filename).ext)
  save(b)

proc rawBackspace(b: Buffer; overrideUtf8=false): string =
  assert b.cursor == b.front.len
  var x = 0
  let ch = b.front[b.cursor-1].c
  if ch.ord < 128 or overrideUtf8:
    x = 1
    if ch == '\L': dec b.numberOfLines
  else:
    while true:
      let (r, L) = lastRune(b, b.cursor-1-x)
      inc(x, L)
      if L > 1 and isCombining(r): discard
      else: break
  # we need to reverse this string here:
  result = newString(x)
  var j = 0
  for i in countdown(b.front.len-1, b.front.len-x):
    result[j] = b.front[i].c
    inc j
  b.cursor -= result.len
  b.front.setLen(b.cursor)

proc backspaceNoSelect(b: Buffer; overrideUtf8=false) =
  if b.cursor <= 0: return
  if b.cursor-1 <= b.readOnly: return
  let oldCursor = b.cursor
  prepareForEdit(b)
  setLen(b.actions, clamp(b.undoIdx+1, 0, b.actions.len))
  let ch = b.rawBackspace(overrideUtf8)
  if b.actions.len > 0 and b.actions[^1].k == dele:
    b.actions[^1].word.add ch
  else:
    b.actions.add(Action(k: dele, pos: b.cursor, word: ch))
  edit(b)
  if ch.len == 1 and ch[0] in Whitespace: b.actions[^1].k = delFinished
  b.desiredCol = getColumn(b)
  highlightLine(b, oldCursor)

proc selectAll*(b: Buffer) =
  b.selected = Marker(a: 0, b: b.len-1, s: mcSelected)

proc getSelectedText*(b: Buffer): string =
  if b.selected.b < 0: return ""
  result = newStringOfCap(b.selected.b - b.selected.a + 1)
  for i in b.selected.a .. b.selected.b:
    result.add b[i]

proc removeSelectedText*(b: Buffer) =
  if b.selected.b < 0: return
  b.cursor = b.selected.b+1
  while b.cursor > b.selected.a:
    backspaceNoSelect(b, true)
  b.selected.b = -1

proc deselect*(b: Buffer) {.inline.} = b.selected.b = -1

proc selectLeft*(b: Buffer; jump: bool) =
  if b.cursor > 0:
    if b.selected.b < 0: b.selected.b = b.cursor
    left(b, jump)
    b.selected.a = b.cursor

proc selectUp*(b: Buffer; jump: bool) =
  if b.cursor > 0:
    if b.selected.b < 0: b.selected.b = b.cursor
    up(b, jump)
    b.selected.a = b.cursor

proc selectRight*(b: Buffer; jump: bool) =
  if b.cursor < b.len:
    if b.selected.b < 0: b.selected.a = b.cursor
    right(b, jump)
    let (_, L) = lastRune(b, b.cursor-1)
    b.selected.b = b.cursor-L

proc selectDown*(b: Buffer; jump: bool) =
  if b.cursor < b.len:
    if b.selected.b < 0: b.selected.a = b.cursor
    down(b, jump)
    let (_, L) = lastRune(b, b.cursor-1)
    b.selected.b = b.cursor-L

proc backspace*(b: Buffer; overrideUtf8=false) =
  if b.selected.b < 0:
    backspaceNoSelect(b, overrideUtf8)
  else:
    removeSelectedText(b)

proc deleteKey*(b: Buffer) =
  if b.selected.b < 0:
    if b.cursor >= b.len: return
    let (r, L) = lastRune(b, b.cursor+1)
    inc(b.cursor, L)
    backspace(b)
  else:
    removeSelectedText(b)

proc insertNoSelect(b: Buffer; s: string) =
  if b.cursor <= b.readOnly or s.len == 0: return
  let oldCursor = b.cursor
  prepareForEdit(b)
  setLen(b.actions, clamp(b.undoIdx+1, 0, b.actions.len))
  if b.actions.len > 0 and b.actions[^1].k == ins:
    b.actions[^1].word.add s
  else:
    b.actions.add(Action(k: ins, pos: b.cursor, word: s))
  if s[^1] in Whitespace: b.actions[^1].k = insFinished
  edit(b)
  rawInsert(b, s)
  b.desiredCol = getColumn(b)
  highlightLine(b, oldCursor)

proc insert*(b: Buffer; s: string) =
  removeSelectedText(b)
  insertNoSelect(b, s)

proc dedentSingleLine(b: Buffer; i: int) =
  if b[i] == '\t':
    b.cursor = i+1
    backspaceNoSelect(b)
    if b.selected.b >= 0: dec b.selected.b
  elif b[i] == ' ':
    var spaces = 1
    while spaces < b.tabSize and b[i+spaces] == ' ':
      inc spaces
    b.cursor = i+spaces
    for j in 1..spaces:
      backspaceNoSelect(b)
      if b.selected.b >= 0: dec b.selected.b

proc dedent*(b: Buffer) =
  if b.selected.b < 0:
    var i = b.cursor
    while i >= 1 and b[i-1] != '\L': dec i
    dedentSingleLine(b, i)
  else:
    var i = b.selected.a
    while i >= 1 and b[i-1] != '\L': dec i
    while i <= b.selected.b:
      dedentSingleLine(b, i)
      inc i
      while i < b.len-1 and b[i] != '\L': inc i
      if b[i] == '\L': inc i

proc indentSingleLine(b: Buffer; i: int) =
  b.cursor = i
  for j in 1..b.tabSize:
    # XXX proper undo handling
    insertNoSelect(b, " ")
    assert b.selected.b >= 0
    inc b.selected.b

proc indent*(b: Buffer) =
  if b.selected.b < 0:
    insert(b, "\t")
  else:
    var i = b.selected.a
    while i >= 1 and b[i-1] != '\L': dec i
    while i <= b.selected.b:
      indentSingleLine(b, i)
      inc i
      while i < b.len-1 and b[i] != '\L': inc i
      if b[i] == '\L': inc i

proc insertEnter*(b: Buffer) =
  # move to the *start* of this line
  var i = b.cursor
  while i >= 1 and b[i-1] != '\L': dec i
  var toInsert = "\L"
  while true:
    let c = b[i]
    if c == ' ' or c == '\t':
      toInsert.add c
    else:
      break
    inc i
  b.insert(toInsert)

proc gotoLine*(b: Buffer; line: int) =
  let line = line-1
  if line >= 0 and line < b.numberOfLines:
    b.cursor = getLineOffset(b, line)
    b.currentLine = line
    b.firstLine = max(0, line - (b.span div 2))
    b.firstLineOffset = getLineOffset(b, b.firstLine)

proc applyUndo(b: Buffer; a: Action) =
  let oldCursor = b.cursor
  if a.k <= insFinished:
    b.cursor = a.pos + a.word.len
    prepareForEdit(b)
    b.cursor = a.pos
    # reverse op of insert is delete:
    b.front.setLen(b.cursor)
  else:
    b.cursor = a.pos
    prepareForEdit(b)
    # reverse op of delete is insert:
    for i in countdown(a.word.len-1, 0):
      b.front.add Cell(c: a.word[i])
    b.cursor += a.word.len
  highlightLine(b, oldCursor)

proc applyRedo(b: Buffer; a: Action) =
  let oldCursor = b.cursor
  if a.k <= insFinished:
    b.cursor = a.pos
    prepareForEdit(b)
    # reverse op of delete is insert:
    for i in countup(0, a.word.len-1):
      b.front.add Cell(c: a.word[i])
    b.cursor += a.word.len
  else:
    b.cursor = a.pos + a.word.len
    prepareForEdit(b)
    b.cursor = a.pos
    # reverse op of insert is delete:
    b.front.setLen(b.cursor)
  highlightLine(b, oldCursor)

proc undo*(b: Buffer) =
  when defined(debugUndo):
    echo "undo ----------------------------------------"
    for i, x in b.actions:
      if i == b.undoIdx:
        echo x, "*"
      else:
        echo x
  if b.undoIdx >= 0 and b.undoIdx < b.actions.len:
    applyUndo(b, b.actions[b.undoIdx])
    dec(b.undoIdx)

proc redo*(b: Buffer) =
  inc(b.undoIdx)
  when defined(debugUndo):
    echo "redo ----------------------------------------"
    for i, x in b.actions:
      if i == b.undoIdx:
        echo x, "*"
      else:
        echo x
  if b.undoIdx >= 0 and b.undoIdx < b.actions.len:
    applyRedo(b, b.actions[b.undoIdx])
  else:
    dec b.undoIdx
