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
