import pixie, pixie/fileformats/svg

# A drawing handed to parseSvg as nodes, without markup: the same drawing as
# its markup, plus the two things only nodes can carry, a decoded picture for
# `<image>` and a ready outline for `<path>`.

proc el(tag: string, attrs: openArray[(string, string)], children: varargs[SvgNode]): SvgNode =
  result = SvgNode(tag: tag)
  for attr in attrs:
    result.attrs.add attr
  for child in children:
    result.children.add child

proc same(a, b: Image): bool =
  if a.width != b.width or a.height != b.height:
    return false
  for y in 0 ..< a.height:
    for x in 0 ..< a.width:
      if a[x, y] != b[x, y]:
        return false
  true

block: # Nodes draw what their markup draws
  let
    markup = """<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30" viewBox="0 0 40 30"><rect width="40" height="30" fill="#102030"/><g transform="translate(5 4) scale(2)" opacity="0.5"><circle cx="5" cy="5" r="4" fill="#ff0000" stroke="#fff" stroke-width="1"/></g><path d="M0 0L10 20H30Z" fill="#00ff00" fill-rule="evenodd"/></svg>"""
    nodes = el("svg", {"width": "40", "height": "30", "viewBox": "0 0 40 30"},
      el("rect", {"width": "40", "height": "30", "fill": "#102030"}),
      el("g", {"transform": "translate(5 4) scale(2)", "opacity": "0.5"},
        el("circle", {"cx": "5", "cy": "5", "r": "4", "fill": "#ff0000",
          "stroke": "#fff", "stroke-width": "1"})),
      el("path", {"d": "M0 0L10 20H30Z", "fill": "#00ff00", "fill-rule": "evenodd"}))
  doAssert same(newImage(parseSvg(markup, 80, 60)), newImage(parseSvg(nodes, 80, 60)))
  doAssert parseSvg(nodes, 40, 30).coversOpaque(40, 30)

block: # A <path> can carry its outline instead of `d`
  let outline = newPath()
  outline.rect(2, 2, 6, 4)
  let
    node = el("path", {"fill": "#ff0000"})
    root = el("svg", {"width": "10", "height": "10"}, node)
  node.path = outline
  let image = newImage(parseSvg(root, 10, 10))
  doAssert image[4, 3] == rgbx(255, 0, 0, 255)
  doAssert image[1, 1] == rgbx(0, 0, 0, 0)

proc picture(): Image =
  ## 4x2: red on the left half, blue on the right.
  result = newImage(4, 2)
  for y in 0 ..< 2:
    for x in 0 ..< 4:
      result[x, y] = if x < 2: rgbx(255, 0, 0, 255) else: rgbx(0, 0, 255, 255)

proc drawImage(aspect: string, opacity = ""): Image =
  let node = el("image", {"x": "2", "y": "2", "width": "8", "height": "8",
    "preserveAspectRatio": aspect, "opacity": opacity})
  node.image = picture()
  result = newImage(parseSvg(el("svg", {"width": "12", "height": "12"}, node), 12, 12))

block: # <image> fits its picture the way preserveAspectRatio says
  let meet = drawImage("xMidYMid meet") # 8x4, centred: rows 4..7
  doAssert meet[3, 5] == rgbx(255, 0, 0, 255)
  doAssert meet[8, 5] == rgbx(0, 0, 255, 255)
  doAssert meet[5, 2].a == 0 and meet[5, 9].a == 0

  let slice = drawImage("xMidYMid slice") # 16x8 centred on the box, clipped to it
  doAssert slice[5, 5] == rgbx(255, 0, 0, 255)
  doAssert slice[6, 5] == rgbx(0, 0, 255, 255)
  doAssert slice[2, 2].a == 255 and slice[9, 9].a == 255
  doAssert slice[1, 5].a == 0 and slice[10, 5].a == 0 # nothing outside the box

  let stretched = drawImage("none") # 8x8
  doAssert stretched[3, 8] == rgbx(255, 0, 0, 255)
  doAssert stretched[8, 3] == rgbx(0, 0, 255, 255)

  let faded = drawImage("none", "0.5")
  doAssert faded[3, 5].a in 126'u8 .. 129'u8

block: # The same picture in the same box is no damage; moved, both boxes are
  let pic = picture()
  proc frame(x: int): Svg =
    let node = el("image", {"x": $x, "y": "0", "width": "4", "height": "2"})
    node.image = pic
    parseSvg(el("svg", {"width": "20", "height": "10"},
      el("rect", {"width": "20", "height": "10", "fill": "#000"}), node), 20, 10)
  doAssert damage(frame(2), frame(2), 20, 10).w == 0
  let moved = damage(frame(2), frame(10), 20, 10)
  doAssert not moved.full and moved.x <= 2 and moved.x + moved.w >= 14

block: # Markup has no way to name a picture: <image> there stays unsupported
  var raised = false
  try:
    discard parseSvg("""<svg width="4" height="4"><image href="x.png" width="4" height="4"/></svg>""")
  except PixieError:
    raised = true
  doAssert raised

block: # An RGB565 target takes an <image> too
  let node = el("image", {"width": "4", "height": "2", "preserveAspectRatio": "none"})
  node.image = picture()
  let target = newImage565(4, 2)
  parseSvg(el("svg", {"width": "4", "height": "2"}, node), 4, 2).renderInto(target)
  doAssert target[0, 0].r > 200 and target[3, 1].b > 200

echo "test_svg_nodes ok"
