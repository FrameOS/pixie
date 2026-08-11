import jpegsuite, pixie, pixie/fileformats/jpeg

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
