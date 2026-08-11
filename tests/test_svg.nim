import pixie, pixie/fileformats/svg, strformat, xrays, xmlparser, xmltree

const files = [
  "line01",
  "polyline01",
  "polygon01",
  "rect01",
  "rect02",
  "circle01",
  "ellipse01",
  "triangle01",
  "quad01",
  "Ghostscript_Tiger",
  "scale",
  "miterlimit",
  "dashes",
  "dragon2"
]

for file in files:
  let image = readImage(&"tests/fileformats/svg/{file}.svg")
  image.xray(&"tests/fileformats/svg/masters/{file}.png")

block:
  let
    svg = parseSvg(
      readFile("tests/fileformats/svg/accessibility-outline.svg"),
      512, 512
    )
    image = newImage(svg)
  image.xray(&"tests/fileformats/svg/masters/accessibility-outline.png")

block:
  # Test using XML node by itself, see: https://github.com/treeform/pixie/pull/533
  let
    xmlNode = parseXml(readFile("tests/fileformats/svg/accessibility-outline.svg"))
    svg = parseSvg(
      xmlNode,
      512, 512
    )

block:
  # renderInto: rasterize straight into a buffer the caller already owns.
  #
  # For a caller that has a correctly sized image to hand — a render canvas, a
  # cell of a larger image — this is the difference between one image and two,
  # which on a memory-tight device is the difference between rendering and not.
  let data = readFile("tests/fileformats/svg/Ghostscript_Tiger.svg")

  block:
    # On a fresh transparent target it must be bit-identical to newImage: that
    # is the same rasterization, and `newImage`'s overwrite-first start is only
    # an optimisation for the case where overwrite and normal agree.
    let
      expected = newImage(parseSvg(data, 200, 200))
      actual = newImage(200, 200)
    parseSvg(data, 200, 200).renderInto(actual)
    doAssert expected.data == actual.data

  block:
    # On a target that already has content it must match rendering on
    # transparent and then compositing the result — which is what it replaces.
    # Materialized rounds twice (rasterize, then blend) where this rounds once,
    # so one step of 8-bit quantization is the allowed difference.
    let fused = newImage(200, 200)
    fused.fill(rgba(20, 120, 60, 255))
    parseSvg(data, 200, 200).renderInto(fused)

    let materialized = newImage(200, 200)
    materialized.fill(rgba(20, 120, 60, 255))
    materialized.draw(newImage(parseSvg(data, 200, 200)), blendMode = NormalBlend)

    var worst = 0
    var differing = 0
    for i in 0 ..< fused.data.len:
      var pixelWorst = 0
      pixelWorst = max(pixelWorst, abs(fused.data[i].r.int - materialized.data[i].r.int))
      pixelWorst = max(pixelWorst, abs(fused.data[i].g.int - materialized.data[i].g.int))
      pixelWorst = max(pixelWorst, abs(fused.data[i].b.int - materialized.data[i].b.int))
      pixelWorst = max(pixelWorst, abs(fused.data[i].a.int - materialized.data[i].a.int))
      if pixelWorst > 0: differing += 1
      worst = max(worst, pixelWorst)
    # The Tiger overlaps hundreds of semi-transparent paths, so the rounding
    # compounds rather than staying at a single step: each composite onto an
    # opaque background quantizes to a slightly different value than the same
    # composite onto transparency does before the final blend. A few units out
    # of 255 is the cost of not allocating the second image.
    doAssert worst <= 4, &"renderInto differs from draw by {worst}"
    doAssert differing * 100 div fused.data.len <= 25,
      &"renderInto differs on {differing * 100 div fused.data.len}% of pixels"
