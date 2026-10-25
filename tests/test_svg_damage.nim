import pixie, pixie/fileformats/svg, strformat, strutils

# `damage` and `renderInto` with an origin: an animation that repaints only
# the box that changed must leave its target as a whole render would, down to
# an antialiasing level at a shape's edge.
# The frames below move a logo-like group (fills, a translucent shadow, a
# stroke) over a full-canvas background, through two buffers in turn as a
# double-buffered LCD does, so each buffer is repainted against the frame it
# held two frames back.

const
  W = 160
  H = 120

proc frame(i: int, extra = ""): string =
  let
    x = (i * 7) mod 100
    y = (i * 5) mod 70
    color = ["#55dfff", "#ff72c8", "#b9ed67"][i div 4 mod 3]
  &"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">""" &
    &"""<rect x="0" y="0" width="{W}" height="{H}" fill="#090b14"/>""" &
    &"""<g transform="translate({x.float + 2.5:.2f} {y.float + 2.5:.2f}) scale(0.5)" opacity="0.32">""" &
    """<path d="M10 10C30 0 50 0 70 10L60 40H20Z" fill="#000"/></g>""" &
    &"""<g transform="translate({x.float:.2f} {y.float:.2f}) scale(0.5)">""" &
    &"""<path d="M10 10C30 0 50 0 70 10L60 40H20Z" fill="{color}"/>""" &
    """<circle cx="40" cy="25" r="6" fill="none" stroke="#fff" stroke-width="3"/></g>""" &
    extra & "</svg>"

proc fresh(doc: string, format: PixelFormat): Image =
  result =
    if format == pfRgb565: newImage565(W, H)
    else: newImage(W, H)
  if format == pfRgb565:
    result.ditherStores = true
  parseSvg(doc, W, H).renderInto(result)

proc animate(format: PixelFormat) =
  var
    buffers = [fresh(frame(0), format), fresh(frame(1), format)]
    held = [parseSvg(frame(0), W, H), parseSvg(frame(1), W, H)]
    repainted = 0
  for i in 2 ..< 40:
    let
      target = buffers[i mod 2]
      next = parseSvg(frame(i), W, H)
      box = damage(held[i mod 2], next, W, H)
    doAssert not box.full, &"frame {i}: comparable frames reported as full"
    if box.w > 0:
      next.renderInto(target.view(box.x, box.y, box.w, box.h), box.x, box.y)
      repainted += box.w * box.h
    held[i mod 2] = next
    let expected = fresh(frame(i), format)
    var nudged = 0
    for y in 0 ..< H:
      for x in 0 ..< W:
        let (got, want) = (target[x, y], expected[x, y])
        if got == want:
          continue
        # The window's translation is folded into each element's transform,
        # so a coordinate can round one float32 ulp off a whole render's and
        # an antialiased edge pixel one coverage level off. Nothing else may
        # differ, and nothing accumulates: the box is repainted whole.
        let step = if format == pfRgb565: 9 else: 1
        doAssert abs(got.r.int - want.r.int) <= step and abs(got.g.int - want.g.int) <= step and
          abs(got.b.int - want.b.int) <= step,
          &"{format} frame {i}: ({x}, {y}) is {got}, a whole render gives {want}"
        inc nudged
    doAssert nudged * 200 < W * H, &"{format} frame {i}: {nudged} pixels off by a rounding"
  # The point of it: well under the whole canvas per frame.
  doAssert repainted < 38 * W * H div 2, $repainted

animate(pfRgbx)
animate(pfRgb565)

block:
  # Nothing changed: an empty box. A different element count, or a changed
  # gradient: full.
  let a = parseSvg(frame(3), W, H)
  doAssert damage(a, parseSvg(frame(3), W, H), W, H) == (false, 0, 0, 0, 0)
  doAssert damage(a, parseSvg(frame(3, "<rect width=\"4\" height=\"4\"/>"), W, H), W, H).full
  let
    g1 = "<defs><linearGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" x1=\"0\" y1=\"0\" x2=\"9\" y2=\"0\">" &
      "<stop offset=\"0\" stop-color=\"#000\"/><stop offset=\"1\" stop-color=\"#fff\"/></linearGradient></defs>" &
      "<rect width=\"9\" height=\"9\" fill=\"url(#g)\"/>"
    g2 = g1.replace("#fff", "#f00")
  doAssert damage(parseSvg(frame(3, g1), W, H), parseSvg(frame(3, g2), W, H), W, H).full
  doAssert damage(nil, a, W, H).full

block:
  # Identical path data is parsed once.
  let
    a = parseSvg(frame(5), W, H)
    b = parseSvg(frame(6), W, H)
  doAssert not damage(a, b, W, H).full

echo "svg damage ok"
