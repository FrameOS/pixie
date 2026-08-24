## Load SVG files.

import chroma, ../common, ../fonts, ../images, ../internal, ../paints,
    ../paths, parsexml, strutils, tables, unicode, vmath, xmlparser, xmltree

when defined(pixieDebugSvg):
  import strtabs

const
  xmlSignature* = "<?xml"
  svgSignature* = "<svg"

type
  Svg* = ref object
    width*, height*: int
    elements: seq[(Path, SvgProperties)]
    gradients: Table[string, SvgGradient]
    viewBoxWidth, viewBoxHeight: float32 # what percentage lengths refer to

  SvgTextAnchor = enum
    StartAnchor, MiddleAnchor, EndAnchor

  SvgBaseline = enum
    AlphabeticBaseline, MiddleBaseline, HangingBaseline, IdeographicBaseline

  SvgProperties = object
    display: bool
    fillRule: WindingRule
    fill: string
    stroke: ColorRGBX
    strokeWidth: float32
    strokeLineCap: LineCap
    strokeLineJoin: LineJoin
    strokeMiterLimit: float32
    strokeDashArray: seq[float32]
    transform: Mat3
    opacity, fillOpacity, strokeOpacity: float32
    fontFamily: string
    fontSize: float32
    fontWeight: int
    fontItalic: bool
    textAnchor: SvgTextAnchor
    baseline: SvgBaseline

  SvgGradient = object
    kind: PaintKind         # LinearGradientPaint or RadialGradientPaint
    x1, y1, x2, y2: float32 # linear: the gradient vector, user space
    cx, cy, r: float32      # radial: centre and radius, user space
    transform: Mat3         # gradientTransform
    stops: seq[ColorStop]

  SvgTypefaceResolver* = proc(
    family: string, weight: int, italic: bool
  ): Typeface {.gcsafe, raises: [].}
    ## Turns a CSS font-family name into a typeface for `<text>`. Called once
    ## per candidate in a `font-family` list, most-preferred first; return nil
    ## to decline and let the next candidate try. Called a final time with an
    ## empty family for the default face, so returning nil there means the text
    ## is skipped rather than the SVG failing.

template failInvalid() =
  raise newException(PixieError, "Invalid SVG data")

var svgTypefaceResolverImpl: SvgTypefaceResolver

proc setSvgTypefaceResolver*(resolver: SvgTypefaceResolver) {.raises: [].} =
  ## Installs the hook `<text>` uses to find typefaces. Pixie ships no fonts, so
  ## without one `<text>` elements are skipped: an application that wants text
  ## rendered supplies its own font lookup here (see `readTypeface`).
  svgTypefaceResolverImpl = resolver

proc svgTypefaceResolver*(): SvgTypefaceResolver {.raises: [].} =
  ## The currently installed typeface resolver, or nil.
  {.cast(gcsafe).}:
    result = svgTypefaceResolverImpl

proc attrOrDefault(node: XmlNode, name, default: string): string =
  result = node.attr(name)
  if result.len == 0:
    result = default

proc initSvgProperties(): SvgProperties =
  result.display = true
  result.fill = "black"
  result.strokeWidth = 1
  result.transform = mat3()
  result.strokeMiterLimit = defaultMiterLimit
  result.opacity = 1
  result.fillOpacity = 1
  result.strokeOpacity = 1
  result.fontSize = 16 # CSS initial value
  result.fontWeight = 400

proc parseSvgFontSize(value: string, inherited: float32): float32 =
  ## font-size in CSS units, resolved to pixels. An unparseable size inherits
  ## rather than failing: a broken font-size must not lose the whole drawing.
  var v = value.strip()
  if v.len == 0:
    return inherited
  case v
  of "xx-small": return 9
  of "x-small": return 10
  of "small": return 13
  of "medium": return 16
  of "large": return 18
  of "x-large": return 24
  of "xx-large": return 32
  of "larger": return inherited * 1.2
  of "smaller": return inherited / 1.2
  of "inherit": return inherited
  else: discard

  var scale: float32 = 1
  template cut(suffix: string, factor: float32) =
    v.setLen(v.len - suffix.len)
    scale = factor
  if v.endsWith("px"): cut("px", 1)
  elif v.endsWith("rem"): cut("rem", inherited)
  elif v.endsWith("em"): cut("em", inherited)
  elif v.endsWith("pt"): cut("pt", 96 / 72)
  elif v.endsWith("pc"): cut("pc", 16)
  elif v.endsWith("in"): cut("in", 96)
  elif v.endsWith("cm"): cut("cm", 96 / 2.54)
  elif v.endsWith("mm"): cut("mm", 96 / 25.4)
  elif v.endsWith("%"): cut("%", inherited / 100)

  try:
    result = parseFloat(v.strip()) * scale
  except ValueError:
    result = inherited
  if result <= 0:
    result = 0

proc parseSvgFontWeight(value: string, inherited: int): int =
  case value.strip():
  of "": inherited
  of "normal", "book", "regular": 400
  of "bold": 700
  of "bolder": min(inherited + 300, 900)
  of "lighter": max(inherited - 300, 100)
  of "inherit": inherited
  else:
    try:
      clamp(parseInt(value.strip()), 1, 1000)
    except ValueError:
      inherited

proc splitArgs(s: string): seq[string] =
  # Handles (1,1) or (1 1) or (1, 1) or (1,1 2,2) etc
  let tmp = s.replace(',', ' ').split(' ')
  for entry in tmp:
    if entry.len > 0:
      result.add(entry)

proc parseSvgTransform(transform: string): Mat3 =
  ## A `transform` (or `gradientTransform`) attribute: a list of matrix,
  ## translate, rotate and scale functions, composed left to right.
  template failInvalidTransform(transform: string) =
    raise newException(
        PixieError, "Unsupported SVG transform: " & transform
      )

  result = mat3()
  var remaining = transform
  while remaining.len > 0:
    let index = remaining.find(")")
    if index == -1:
      failInvalidTransform(transform)
    let f = remaining[0 .. index].strip()
    remaining = remaining[index + 1 .. ^1]

    if f.startsWith("matrix("):
      let arr = splitArgs(f[7 .. ^2])
      if arr.len != 6:
        failInvalidTransform(transform)
      var m = mat3()
      m[0, 0] = parseFloat(arr[0])
      m[0, 1] = parseFloat(arr[1])
      m[1, 0] = parseFloat(arr[2])
      m[1, 1] = parseFloat(arr[3])
      m[2, 0] = parseFloat(arr[4])
      m[2, 1] = parseFloat(arr[5])
      result = result * m
    elif f.startsWith("translate("):
      let
        components = splitArgs(f[10 .. ^2])
        tx = parseFloat(components[0])
        ty =
          if components.len == 1:
            0.0
          else:
            parseFloat(components[1])
      result = result * translate(vec2(tx, ty))
    elif f.startsWith("rotate("):
      let
        values = splitArgs(f[7 .. ^2])
        angle: float32 = parseFloat(values[0]) * PI / 180
      var cx, cy: float32
      if values.len > 1:
        cx = parseFloat(values[1])
      if values.len > 2:
        cy = parseFloat(values[2])
      let center = vec2(cx, cy)
      result = result * translate(center) * rotate(angle) * translate(-center)
    elif f.startsWith("scale("):
      let
        values = splitArgs(f[6 .. ^2])
        sx: float32 = parseFloat(values[0])
        sy: float32 =
          if values.len > 1:
            parseFloat(values[1])
          else:
            sx
      result = result * scale(vec2(sx, sy))
    else:
      failInvalidTransform(transform)

proc parseSvgProperties(node: XmlNode, inherited: SvgProperties): SvgProperties =
  result = inherited

  var
    fillRule = node.attr("fill-rule")
    fill = node.attr("fill")
    stroke = node.attr("stroke")
    strokeWidth = node.attr("stroke-width")
    strokeLineCap = node.attr("stroke-linecap")
    strokeLineJoin = node.attr("stroke-linejoin")
    strokeMiterLimit = node.attr("stroke-miterlimit")
    strokeDashArray = node.attr("stroke-dasharray")
    transform = node.attr("transform")
    style = node.attr("style")
    display = node.attr("display")
    opacity = node.attr("opacity")
    fillOpacity = node.attr("fill-opacity")
    strokeOpacity = node.attr("stroke-opacity")
    fontFamily = node.attr("font-family")
    fontSize = node.attr("font-size")
    fontWeight = node.attr("font-weight")
    fontStyle = node.attr("font-style")
    textAnchor = node.attr("text-anchor")
    baseline = node.attrOrDefault(
      "dominant-baseline", node.attr("alignment-baseline")
    )

  when defined(pixieDebugSvg):
    proc maybeLogPair(k, v: string) =
      if k notin [
          "fill-rule", "fill", "stroke", "stroke-width", "stroke-linecap",
          "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray",
          "transform", "style", "version", "viewBox", "width", "height",
          "xmlns", "x", "y", "x1", "x2", "y1", "y2", "id", "d", "cx", "cy",
          "r", "points", "rx", "ry", "enable-background", "xml:space",
          "xmlns:xlink", "data-name", "role", "class", "opacity",
          "fill-opacity", "stroke-opacity", "font-family", "font-size",
          "font-weight", "font-style", "text-anchor", "dominant-baseline",
          "alignment-baseline", "dx", "dy"
        ]:
          echo k, ": ", v

    if node.attrs() != nil:
      for k, v in node.attrs():
        maybeLogPair(k, v)

  let pairs = style.split(';')
  for pair in pairs:
    let parts = pair.split(':')
    if parts.len == 2:
      # Do not override element properties
      case parts[0].strip():
      of "fill-rule":
        if fillRule.len == 0:
          fillRule = parts[1].strip()
      of "fill":
        if fill.len == 0:
          fill = parts[1].strip()
      of "stroke":
        if stroke.len == 0:
          stroke = parts[1].strip()
      of "stroke-linecap":
        if strokeLineCap.len == 0:
          strokeLineCap = parts[1].strip()
      of "stroke-linejoin":
        if strokeLineJoin.len == 0:
          strokeLineJoin = parts[1].strip()
      of "stroke-width":
        if strokeWidth.len == 0:
          strokeWidth = parts[1].strip()
      of "stroke-miterlimit":
        if strokeMiterLimit.len == 0:
          strokeMiterLimit = parts[1].strip()
      of "stroke-dasharray":
        if strokeDashArray.len == 0:
          strokeDashArray = parts[1].strip()
      of "display":
        if display.len == 0:
          display = parts[1].strip()
      of "opacity":
        if opacity.len == 0:
          opacity = parts[1].strip()
      of "fillOpacity":
        if fillOpacity.len == 0:
          fillOpacity = parts[1].strip()
      of "strokeOpacity":
        if strokeOpacity.len == 0:
          strokeOpacity = parts[1].strip()
      of "font-family":
        if fontFamily.len == 0:
          fontFamily = parts[1].strip()
      of "font-size":
        if fontSize.len == 0:
          fontSize = parts[1].strip()
      of "font-weight":
        if fontWeight.len == 0:
          fontWeight = parts[1].strip()
      of "font-style":
        if fontStyle.len == 0:
          fontStyle = parts[1].strip()
      of "text-anchor":
        if textAnchor.len == 0:
          textAnchor = parts[1].strip()
      of "dominant-baseline", "alignment-baseline":
        if baseline.len == 0:
          baseline = parts[1].strip()
      else:
        when defined(pixieDebugSvg):
          maybeLogPair(parts[0], parts[1])
    elif pair.len > 0:
      when defined(pixieDebugSvg):
        echo "Invalid style pair: ", pair

  if display.len > 0:
    result.display = display.strip() != "none"

  if opacity.len > 0:
    result.opacity = clamp(parseFloat(opacity), 0, 1)

  if fillRule == "":
    discard # Inherit
  elif fillRule == "nonzero":
    result.fillRule = NonZero
  elif fillRule == "evenodd":
    result.fillRule = EvenOdd
  else:
    raise newException(
      PixieError, "Invalid fill-rule value " & fillRule
    )

  if fill == "" or fill == "currentColor":
    result.fill = inherited.fill
  else:
    result.fill = fill

  if stroke == "":
    discard # Inherit
  elif stroke == "currentColor":
    if result.stroke == rgbx(0, 0, 0, 0):
      result.stroke = rgbx(0, 0, 0, 255)
  elif stroke == "none":
    result.stroke = ColorRGBX()
  else:
    result.stroke = parseHtmlColor(stroke).rgbx

  if fillOpacity.len > 0:
    result.fillOpacity = parseFloat(fillOpacity).clamp(0, 1)

  if strokeOpacity.len > 0:
    result.strokeOpacity = parseFloat(strokeOpacity).clamp(0, 1)

  if strokeWidth == "":
    discard # Inherit
  else:
    if strokeWidth.endsWith("px"):
      strokeWidth = strokeWidth[0 .. ^3]
    result.strokeWidth = parseFloat(strokeWidth)
    if result.stroke == rgbx(0, 0, 0, 0):
      result.stroke = rgbx(0, 0, 0, 255)

  if strokeLineCap == "":
    discard # Inherit
  else:
    case strokeLineCap:
    of "butt":
      result.strokeLineCap = ButtCap
    of "round":
      result.strokeLineCap = RoundCap
    of "square":
      result.strokeLineCap = SquareCap
    of "inherit":
      discard
    else:
      raise newException(
        PixieError, "Invalid stroke-linecap value " & strokeLineCap
      )

  if strokeLineJoin == "":
    discard # Inherit
  else:
    case strokeLineJoin:
    of "miter":
      result.strokeLineJoin = MiterJoin
    of "round":
      result.strokeLineJoin = RoundJoin
    of "bevel":
      result.strokeLineJoin = BevelJoin
    of "inherit":
      discard
    else:
      raise newException(
        PixieError, "Invalid stroke-linejoin value " & strokeLineJoin
      )

  if strokeMiterLimit == "":
    discard
  else:
    result.strokeMiterLimit = parseFloat(strokeMiterLimit)

  if fontFamily.len > 0 and fontFamily != "inherit":
    result.fontFamily = fontFamily

  result.fontSize = parseSvgFontSize(fontSize, inherited.fontSize)
  result.fontWeight = parseSvgFontWeight(fontWeight, inherited.fontWeight)

  case fontStyle.strip():
  of "": discard # Inherit
  of "italic", "oblique": result.fontItalic = true
  of "normal": result.fontItalic = false
  else: discard # Unknown font-style: keep inheriting rather than fail

  case textAnchor.strip():
  of "": discard # Inherit
  of "middle": result.textAnchor = MiddleAnchor
  of "end": result.textAnchor = EndAnchor
  of "start": result.textAnchor = StartAnchor
  else: discard

  case baseline.strip():
  of "": discard # Inherit
  of "middle", "central": result.baseline = MiddleBaseline
  of "hanging", "text-before-edge", "top": result.baseline = HangingBaseline
  of "text-after-edge", "ideographic", "bottom":
    result.baseline = IdeographicBaseline
  of "auto", "alphabetic", "baseline", "mathematical":
    result.baseline = AlphabeticBaseline
  else: discard

  if strokeDashArray == "":
    discard
  else:
    var values = splitArgs(strokeDashArray)
    for value in values:
      result.strokeDashArray.add(parseFloat(value))

  if transform == "":
    discard # Inherit
  else:
    result.transform = result.transform * parseSvgTransform(transform)

type
  SvgTextPosition = object
    hasX, hasY: bool
    x, y, dx, dy: float32

  SvgTextRun = object
    text: string
    props: SvgProperties
    pos: SvgTextPosition

proc svgEntityText(name: string): string =
  ## `parsexml` resolves numeric entities and the five predefined ones itself,
  ## so what reaches an entity node is a named entity. These are the ones that
  ## turn up in hand-written and generated SVG; anything else contributes
  ## nothing rather than failing the drawing.
  case name
  of "nbsp": " " # A normal space: fonts often lack U+00A0 and would draw tofu
  of "ndash": "–"
  of "mdash": "—"
  of "hellip": "…"
  of "lsquo": "‘"
  of "rsquo": "’"
  of "ldquo": "“"
  of "rdquo": "”"
  of "bull": "•"
  of "middot": "·"
  of "times": "×"
  of "deg": "°"
  of "copy": "©"
  of "reg": "®"
  of "trade": "™"
  of "euro": "€"
  of "pound": "£"
  of "yen": "¥"
  else: ""

proc collapseSvgWhitespace(text: string, lastWasSpace: var bool): string =
  ## XML whitespace inside `<text>` is layout, not content: newlines and the
  ## indentation around a `<tspan>` collapse to a single space. `lastWasSpace`
  ## carries across runs so `<text> a <tspan>b</tspan> </text>` does not gain
  ## spaces at the seams, and starts true so leading indentation disappears.
  for c in text:
    if c in Whitespace:
      if not lastWasSpace:
        result.add ' '
        lastWasSpace = true
    else:
      result.add c
      lastWasSpace = false

proc parseSvgCoordinate(value: string, default: float32 = 0): float32 =
  ## The first number of an SVG coordinate attribute. `x="10 20 30"` positions
  ## glyphs individually; v1 takes the first and advances the rest normally.
  var s = value.strip()
  let sep = s.find({' ', ',', '\t', '\n', '\r'})
  if sep > 0:
    s.setLen(sep)
  # SVG2 allows units on geometry attributes; treat them as user units.
  while s.len > 0 and s[^1] in {'a' .. 'z', 'A' .. 'Z', '%'}:
    s.setLen(s.len - 1)
  try:
    parseFloat(s)
  except ValueError:
    default

proc resolveSvgTypeface(props: SvgProperties): Typeface =
  ## Walks the font-family list, most-preferred first, and asks the resolver for
  ## each. An unknown family falls through to the resolver's default rather than
  ## failing: text in the wrong face still says what it says.
  let resolver = svgTypefaceResolver()
  if resolver == nil:
    return nil
  for candidate in props.fontFamily.split(','):
    let family = candidate.strip().strip(chars = {'"', '\'', ' '})
    if family.len == 0:
      continue
    let typeface = resolver(family, props.fontWeight, props.fontItalic)
    if typeface != nil:
      return typeface
  resolver("", props.fontWeight, props.fontItalic)

proc walkSvgText(
  node: XmlNode,
  inherited: SvgProperties,
  runs: var seq[SvgTextRun],
  lastWasSpace: var bool,
  pending: var SvgTextPosition
) =
  ## Flattens a `<text>` element (and any nested `<tspan>`s) into runs of text,
  ## each carrying the properties and the pending position adjustment that apply
  ## to its first character.
  let props = node.parseSvgProperties(inherited)

  let
    x = node.attr("x")
    y = node.attr("y")
    dx = node.attr("dx")
    dy = node.attr("dy")
  if x.len > 0:
    pending.hasX = true
    pending.x = parseSvgCoordinate(x)
  if y.len > 0:
    pending.hasY = true
    pending.y = parseSvgCoordinate(y)
  if dx.len > 0:
    pending.dx += parseSvgCoordinate(dx)
  if dy.len > 0:
    pending.dy += parseSvgCoordinate(dy)

  for child in node:
    case child.kind
    of xnText, xnCData, xnVerbatimText:
      let text = collapseSvgWhitespace(child.text, lastWasSpace)
      if text.len > 0:
        runs.add SvgTextRun(text: text, props: props, pos: pending)
        pending = SvgTextPosition()
    of xnEntity:
      let text = svgEntityText(child.text)
      if text.len > 0:
        lastWasSpace = false
        runs.add SvgTextRun(text: text, props: props, pos: pending)
        pending = SvgTextPosition()
    of xnElement:
      case child.tag
      of "tspan", "text", "a":
        child.walkSvgText(props, runs, lastWasSpace, pending)
      else:
        # <textPath>, <title>, <desc>, <tref>: no v1 support, and dropping the
        # element is better than losing the document it sits in.
        discard
    else:
      discard

proc parseSvgText(
  node: XmlNode, props: SvgProperties
): seq[(Path, SvgProperties)] =
  ## Turns a `<text>` element into glyph outlines. They are ordinary paths from
  ## there on: fill, stroke, gradients, opacity and transforms all apply exactly
  ## as they do to a `<path>`.
  if svgTypefaceResolver() == nil:
    # No font source installed. Skipping the text keeps the rest of the
    # drawing, which is what a missing font should cost.
    return

  var
    runs: seq[SvgTextRun]
    lastWasSpace = true
    pending = SvgTextPosition(hasX: true, hasY: true) # x=0 y=0 unless given
  node.walkSvgText(props, runs, lastWasSpace, pending)
  if runs.len == 0:
    return

  if runs[^1].text.endsWith(" "):
    # Renders nothing, but would widen the chunk that text-anchor centers.
    runs[^1].text.setLen(runs[^1].text.len - 1)

  var
    arrangements = newSeq[Arrangement](runs.len)
    fonts = newSeq[Font](runs.len)
    origins = newSeq[Vec2](runs.len)
    widths = newSeq[float32](runs.len)
    chunkStarts: seq[int]
    pen: Vec2

  for i, run in runs:
    if run.pos.hasX:
      pen.x = run.pos.x
      chunkStarts.add i
    if run.pos.hasY:
      pen.y = run.pos.y
    pen.x += run.pos.dx
    pen.y += run.pos.dy
    origins[i] = pen

    if run.props.fontSize <= 0:
      continue
    let typeface = resolveSvgTypeface(run.props)
    if typeface == nil:
      continue
    let font = newFont(typeface)
    font.size = run.props.fontSize
    fonts[i] = font
    # No bounds, no wrapping: SVG text is one line unless the author breaks it
    # into positioned tspans.
    arrangements[i] = font.typeset(run.text, wrap = false)
    widths[i] = arrangements[i].layoutBounds().x
    pen.x += widths[i]

  for c, start in chunkStarts:
    let
      stop = if c + 1 < chunkStarts.len: chunkStarts[c + 1] - 1 else: runs.high
      anchor = runs[start].props.textAnchor
    if anchor == StartAnchor:
      continue
    let
      width = origins[stop].x + widths[stop] - origins[start].x
      shift = if anchor == MiddleAnchor: -width / 2 else: -width
    for i in start .. stop:
      origins[i].x += shift

  for i, run in runs:
    if fonts[i] == nil or run.text.strip().len == 0:
      continue
    let
      font = fonts[i]
      typeface = font.typeface
      scale = font.scale
      baselineShift =
        case run.props.baseline
        of AlphabeticBaseline: 0.float32
        of MiddleBaseline: (typeface.ascent + typeface.descent) / 2 * scale
        of HangingBaseline: typeface.ascent * scale
        of IdeographicBaseline: typeface.descent * scale
      path = arrangements[i].computePath()
    # `typeset` puts the first baseline at `baselineOffset` below the top of the
    # block; SVG gives us the baseline itself, so shift the block up by that.
    path.transform(translate(vec2(
      origins[i].x,
      origins[i].y + baselineShift - font.baselineOffset
    )))
    result.add (path, run.props)

proc parseSvgLength(value: string, reference: float32): float32 =
  ## A gradient coordinate: a user-space number, or a percentage of
  ## `reference` (the viewport's width, height or normalised diagonal).
  let v = value.strip()
  if v.endsWith("%"):
    parseFloat(v[0 .. ^2]).float32 / 100 * reference
  else:
    parseFloat(v)

proc parseSvgGradientStops(node: XmlNode): seq[ColorStop] =
  for child in node:
    if child.kind != xnElement:
      # Whitespace between the stops, reported for documents with text in
      # them (see parseSvgXml). Not a tag, and `tag` on it would be a defect.
      continue
    if child.tag == "stop":
      var
        color = child.attr("stop-color")
        opacity = child.attr("stop-opacity")

      let
        style = child.attr("style")
        pairs = style.split(';')
      for pair in pairs:
        let parts = pair.split(':')
        if parts.len == 2:
          # Do not override element properties
          case parts[0].strip():
          of "stop-color":
            if color == "":
              color = parts[1].strip()
          of "stop-opacity":
            if opacity == "":
              opacity = parts[1].strip()
          else:
            when defined(pixieDebugSvg):
              echo parts[0], ": ", parts[1]
        elif pair.len > 0:
          when defined(pixieDebugSvg):
            echo "Invalid style pair: ", pair

      if color == "":
        raise newException(
          PixieError, "Invalid SVG gradient, missing stop-color"
        )

      var stop = ColorStop(
        color: color.parseHtmlColor(),
        position: parseSvgLength(child.attr("offset"), 1)
      )
      if opacity != "":
        stop.color.a *= parseFloat(opacity).clamp(0, 1)
      result.add stop
    else:
      raise newException(PixieError, "Unexpected SVG tag: " & child.tag)

proc parseSvgGradient(node: XmlNode, svg: Svg) =
  ## `<linearGradient>` and `<radialGradient>`, registered by id for fills to
  ## reference as `url(#id)`. Coordinates are user space (`gradientUnits=
  ## "userSpaceOnUse"`, the only supported units), numbers or percentages of
  ## the viewport, with the SVG defaults when absent; `gradientTransform`
  ## applies on top. A radial gradient's focal point (fx, fy) and
  ## `spreadMethod` are read as their defaults: the ramp is centred and pads.
  let
    id = node.attr("id")
    gradientUnits = node.attr("gradientUnits")
    gradientTransform = node.attr("gradientTransform")

  if gradientUnits != "userSpaceOnUse":
    raise newException(
      PixieError, "Unsupported gradient units: " & gradientUnits
    )

  var gradient: SvgGradient
  gradient.transform =
    if gradientTransform == "": mat3()
    else: parseSvgTransform(gradientTransform)

  let
    w = svg.viewBoxWidth
    h = svg.viewBoxHeight
  if node.tag == "linearGradient":
    gradient.kind = LinearGradientPaint
    gradient.x1 = parseSvgLength(node.attrOrDefault("x1", "0%"), w)
    gradient.y1 = parseSvgLength(node.attrOrDefault("y1", "0%"), h)
    gradient.x2 = parseSvgLength(node.attrOrDefault("x2", "100%"), w)
    gradient.y2 = parseSvgLength(node.attrOrDefault("y2", "0%"), h)
  else:
    gradient.kind = RadialGradientPaint
    gradient.cx = parseSvgLength(node.attrOrDefault("cx", "50%"), w)
    gradient.cy = parseSvgLength(node.attrOrDefault("cy", "50%"), h)
    gradient.r = parseSvgLength(
      node.attrOrDefault("r", "50%"), sqrt((w * w + h * h) / 2)
    )

  gradient.stops = node.parseSvgGradientStops()
  svg.gradients[id] = gradient

proc parseSvgElement(
  node: XmlNode, svg: Svg, propertiesStack: var seq[SvgProperties]
): seq[(Path, SvgProperties)] =
  if node.kind != xnElement:
    # Skip <!-- comments -->
    return

  case node.tag:
  of "title", "desc":
    discard

  of "defs":
    # Where documents keep their gradients. Anything else defined here
    # (patterns, clip paths, symbols) is not drawn, as before.
    for child in node:
      if child.kind == xnElement and
          child.tag in ["linearGradient", "radialGradient"]:
        child.parseSvgGradient(svg)
      else:
        when defined(pixieDebugSvg):
          echo child

  of "g":
    let props = node.parseSvgProperties(propertiesStack[^1])
    propertiesStack.add(props)
    for child in node:
      result.add child.parseSvgElement(svg, propertiesStack)
    discard propertiesStack.pop()

  of "text":
    result.add node.parseSvgText(propertiesStack[^1])

  of "path":
    let
      d = node.attr("d")
      props = node.parseSvgProperties(propertiesStack[^1])
      path = parsePath(d)

    result.add (path, props)

  of "line":
    let
      props = node.parseSvgProperties(propertiesStack[^1])
      x1 = parseFloat(node.attrOrDefault("x1", "0"))
      y1 = parseFloat(node.attrOrDefault("y1", "0"))
      x2 = parseFloat(node.attrOrDefault("x2", "0"))
      y2 = parseFloat(node.attrOrDefault("y2", "0"))

    let path = newPath()
    path.moveTo(x1, y1)
    path.lineTo(x2, y2)

    result.add (path, props)

  of "polyline", "polygon":
    let
      props = node.parseSvgProperties(propertiesStack[^1])
      points = node.attr("points")

    var vecs: seq[Vec2]
    if points.contains(","):
      for pair in points.split(" "):
        let parts = pair.split(",")
        if parts.len != 2:
          failInvalid()
        vecs.add(vec2(parseFloat(parts[0]), parseFloat(parts[1])))
    else:
      let points = points.split(" ")
      if points.len mod 2 != 0:
        failInvalid()
      for i in 0 ..< points.len div 2:
        vecs.add(vec2(parseFloat(points[i * 2]), parseFloat(points[i * 2 + 1])))

    if vecs.len == 0:
      failInvalid()

    let path = newPath()
    path.moveTo(vecs[0])
    for i in 1 ..< vecs.len:
      path.lineTo(vecs[i])

    # The difference between polyline and polygon is whether we close the path
    # and fill or not
    if node.tag == "polygon":
      path.closePath()

    result.add (path, props)

  of "rect":
    let
      props = node.parseSvgProperties(propertiesStack[^1])
      x = parseFloat(node.attrOrDefault("x", "0"))
      y = parseFloat(node.attrOrDefault("y", "0"))
      width = parseFloat(node.attrOrDefault("width", "0"))
      height = parseFloat(node.attrOrDefault("height", "0"))

    if width == 0 or height == 0:
      return

    var
      rx = max(parseFloat(node.attrOrDefault("rx", "0")), 0)
      ry = max(parseFloat(node.attrOrDefault("ry", "0")), 0)

    let path = newPath()
    if rx > 0 or ry > 0:
      if rx == 0:
        rx = ry
      elif ry == 0:
        ry = rx
      rx = min(rx, width / 2)
      ry = min(ry, height / 2)

      path.moveTo(x + rx, y)
      path.lineTo(x + width - rx, y)
      path.ellipticalArcTo(rx, ry, 0, false, true, x + width, y + ry)
      path.lineTo(x + width, y + height - ry)
      path.ellipticalArcTo(rx, ry, 0, false, true, x + width - rx, y + height)
      path.lineTo(x + rx, y + height)
      path.ellipticalArcTo(rx, ry, 0, false, true, x, y + height - ry)
      path.lineTo(x, y + ry)
      path.ellipticalArcTo(rx, ry, 0, false, true, x + rx, y)
    else:
      path.rect(x, y, width, height)

    result.add (path, props)

  of "circle", "ellipse":
    let
      props = node.parseSvgProperties(propertiesStack[^1])
      cx = parseFloat(node.attrOrDefault("cx", "0"))
      cy = parseFloat(node.attrOrDefault("cy", "0"))

    var rx, ry: float32
    if node.tag == "circle":
      rx = parseFloat(node.attr("r"))
      ry = rx
    else:
      rx = parseFloat(node.attrOrDefault("rx", "0"))
      ry = parseFloat(node.attrOrDefault("ry", "0"))

    let path = newPath()
    path.ellipse(cx, cy, rx, ry)

    result.add (path, props)

  of "linearGradient", "radialGradient":
    node.parseSvgGradient(svg)

  else:
    raise newException(PixieError, "Unsupported SVG tag: " & node.tag)

proc parseSvg*(
  root: XmlNode, width = 0, height = 0
): Svg {.raises: [PixieError].} =
  ## Parse SVG XML. Defaults to the SVG's view box size.
  try:
    if root.tag != "svg":
      failInvalid()

    let
      viewBox = root.attr("viewBox")
      box = viewBox.split(" ")
      viewBoxMinX = parseInt(box[0])
      viewBoxMinY = parseInt(box[1])
      viewBoxWidth = parseInt(box[2])
      viewBoxHeight = parseInt(box[3])

    var rootProps = initSvgProperties()
    rootProps = root.parseSvgProperties(rootProps)

    if viewBoxMinX != 0 or viewBoxMinY != 0:
      let viewBoxMin = vec2(-viewBoxMinX.float32, -viewBoxMinY.float32)
      rootProps.transform = rootProps.transform * translate(viewBoxMin)

    result = Svg(
      viewBoxWidth: viewBoxWidth.float32,
      viewBoxHeight: viewBoxHeight.float32
    )

    if width == 0 and height == 0: # Default to the view box size
      result.width = viewBoxWidth
      result.height = viewBoxHeight
    else:
      result.width = width
      result.height = height

      let
        scaleX = width.float32 / viewBoxWidth.float32
        scaleY = height.float32 / viewBoxHeight.float32
      rootProps.transform = rootProps.transform * scale(vec2(scaleX, scaleY))

    var propertiesStack = @[rootProps]
    for node in root.items:
      result.elements.add node.parseSvgElement(result, propertiesStack)
  except PixieError as e:
    raise e
  except:
    raise currentExceptionAsPixieError()

proc parseSvgXml*(data: string): XmlNode {.raises: [PixieError].} =
  ## Parses SVG markup into XML, the way `parseSvg` needs it. Callers that want
  ## the tree itself — to rewrite the root transform and render in bands, say —
  ## should come through here rather than calling `parseXml` directly.
  ##
  ## Nim's parser drops whitespace that follows a closing tag unless asked for
  ## it, which is invisible everywhere except inside `<text>`, where the space
  ## in `…</tspan> tail` is content. Asking for it costs a node per run of
  ## whitespace in the document, so only documents with text pay.
  try:
    var options = {reportComments}
    if data.contains("<text") or data.contains("<tspan"):
      options.incl reportWhitespace
    result = parseXml(data, options)
  except PixieError as e:
    raise e
  except:
    raise currentExceptionAsPixieError()

proc parseSvg*(data: string, width = 0, height = 0): Svg {.raises: [PixieError].} =
  ## Parse SVG data. Defaults to the SVG's view box size.
  try:
    let root = parseSvgXml(data)
    result = root.parseSvg(width, height)
  except PixieError as e:
    raise e
  except:
    raise currentExceptionAsPixieError()

proc renderSvg(
  svg: Svg, target: Image, firstBlendMode: BlendMode
) {.raises: [PixieError].} =
  try:
    var blendMode = firstBlendMode
    for (path, props) in svg.elements:
      if props.display and props.opacity > 0:
        if props.fill != "none":
          var paint: Paint
          if props.fill.startsWith("url("):
            let closingParen = props.fill.find(")", 5)
            if closingParen == -1:
              raise newException(PixieError, "Malformed fill: " & props.fill)
            let id = props.fill[5 .. closingParen - 1]
            if id in svg.gradients:
              let
                gradient = svg.gradients[id]
                transform = props.transform * gradient.transform
              paint = newPaint(gradient.kind)
              case gradient.kind
              of RadialGradientPaint:
                # pixie's radial paint takes the centre plus a point on the
                # circle along each axis; the transform turns those into the
                # ellipse the SVG asks for.
                paint.gradientHandlePositions = @[
                  transform * vec2(gradient.cx, gradient.cy),
                  transform * vec2(gradient.cx + gradient.r, gradient.cy),
                  transform * vec2(gradient.cx, gradient.cy + gradient.r)
                ]
              else:
                paint.gradientHandlePositions = @[
                  transform * vec2(gradient.x1, gradient.y1),
                  transform * vec2(gradient.x2, gradient.y2)
                ]
              paint.gradientStops = gradient.stops
            else:
              raise newException(PixieError, "Missing SVG resource " & id)
          else:
            paint = parseHtmlColor(props.fill).rgbx

          paint.opacity = props.fillOpacity * props.opacity
          paint.blendMode = blendMode

          target.fillPath(path, paint, props.transform, props.fillRule)

        blendMode = NormalBlend # Switch to normal when compositing multiple paths

        if props.stroke != rgbx(0, 0, 0, 0) and props.strokeWidth > 0:
          let paint = props.stroke.copy()
          paint.color.a *= (props.opacity * props.strokeOpacity)
          target.strokePath(
            path,
            paint,
            props.transform,
            props.strokeWidth,
            props.strokeLineCap,
            props.strokeLineJoin,
            miterLimit = props.strokeMiterLimit,
            dashes = props.strokeDashArray
          )
  except PixieError as e:
    raise e
  except:
    raise currentExceptionAsPixieError()

proc renderInto*(svg: Svg, target: Image) {.raises: [PixieError].} =
  ## Render SVG into an existing image, compositing onto whatever is already
  ## there. Nothing is allocated: for a caller that already owns a correctly
  ## sized buffer — a render canvas, a cell of a larger image — this is the
  ## difference between one image and two.
  ##
  ## Unlike `newImage`, the first path composites rather than overwrites.
  ## `newImage` can start in overwrite because its image is freshly
  ## transparent, where the two are identical; on a target that already has
  ## content they are not, and a semi-transparent first path would replace what
  ## is underneath instead of blending with it.
  svg.renderSvg(target, NormalBlend)

proc newImage*(svg: Svg): Image {.raises: [PixieError].} =
  ## Render SVG and return the image.
  result = newImage(svg.width, svg.height)
  svg.renderSvg(result, OverwriteBlend) # Fresh image: overwrite == normal

