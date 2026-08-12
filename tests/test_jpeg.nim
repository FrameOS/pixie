import std/strutils
import jpegsuite, pixie, pixie/fileformats/jpeg, pixie/decodebudget

for file in jpegSuiteFiles:
  let
    image = readImage(file)
    dimensions = decodeJpegDimensions(readFile(file))
  doAssert image.width == dimensions.width
  doAssert image.height == dimensions.height

block:
  var data = readFile("tests/fileformats/jpeg/masters/cat_4_2_0.jpg")
  let image = decodeJpegScaled(data, 17, 11)
  doAssert image.width == 17
  doAssert image.height == 11
  doAssert data.len == 0

block:
  var data = readFile("tests/fileformats/jpeg/masters/cat_4_4_4.jpg")
  let target = newImage(13, 9)
  decodeJpegScaledInto(data, target)
  doAssert target.width == 13
  doAssert target.height == 9
  doAssert data.len == 0

block:
  # Little-endian (II) EXIF must decode identically to the big-endian (MM)
  # originals: the orientation SHORT sits in the opposite word of the data
  # field, which `shr 16` alone silently dropped (Sony/Canon files).
  for n in 1 .. 8:
    let
      mm = decodeJpeg(readFile("tests/fileformats/jpeg/masters/f" & $n & "-exif.jpg"))
      ii = decodeJpeg(readFile("tests/fileformats/jpeg/masters/f" & $n & "-exif-ii.jpg"))
    doAssert ii.width == mm.width and ii.height == mm.height
    doAssert ii.pixelsEqual(mm)

block:
  # The decode plan must count what the decode actually allocates. Two things
  # historically escaped it: the reconstruction path magnifies subsampled
  # channels up to full stride resolution (with the half-size source still
  # alive during the last doubling), and buildImage allocates the output image
  # next to everything the plan approved. A plan that under-counts is a check
  # that passes and an allocation that dies on a fragmented embedded heap.
  let budgetData = readFile("tests/fileformats/jpeg/masters/cat_4_2_0.jpg")
  let budgetDims = decodeJpegDimensions(budgetData)

  # 1) The refusal is catchable and its accounted total covers the
  #    full-resolution upsample peak, not the subsampled starting planes.
  setDecodeBudgetBytes(1)
  var plannedK = 0
  try:
    discard decodeJpeg(budgetData)
    doAssert false, "a 1-byte budget cannot admit any decode plan"
  except PixieError as e:
    doAssert "memory budget" in e.msg, e.msg
    let needsAt = e.msg.find("needs ") + 6
    let kAt = e.msg.find("K of decode")
    plannedK = parseInt(e.msg[needsAt ..< kAt])
  let
    strideW = ((budgetDims.width + 15) div 16) * 16
    strideH = ((budgetDims.height + 15) div 16) * 16
    fullMask = strideW * strideH
  doAssert plannedK * 1024 >= fullMask + 2 * (fullMask + fullMask div 2),
    "the plan no longer counts the chroma upsample peak: " & $plannedK & "K"

  # 2) Buffers fit, the output image does not: still a catchable refusal,
  #    naming the output.
  setDecodeBudgetBytes(plannedK * 1024 + 2048)
  try:
    discard decodeJpeg(budgetData)
    doAssert false, "the output image cannot fit in 2K of headroom"
  except PixieError as e:
    doAssert "JPEG output of" in e.msg and "memory budget" in e.msg, e.msg

  # 3) Honest headroom decodes.
  setDecodeBudgetBytes(plannedK * 1024 +
    budgetDims.width * budgetDims.height * 4 + 1024 * 1024)
  doAssert decodeJpeg(budgetData).width == budgetDims.width
  setDecodeBudgetBytes(0)
