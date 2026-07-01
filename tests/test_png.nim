import pixie, pixie/fileformats/png, pngsuite, strformat

when defined(writeImages):
  import write_images

when defined(writeImages):
  resetOutputDir(pngSuiteOutputDir)
  echo &"Writing decoded PNGSuite images to {pngSuiteOutputDir}"

for file in pngSuiteFiles:
  let
    original = readFile(&"tests/fileformats/png/pngsuite/{file}.png")
    decoded = decodePng(original)
    encoded = encodePng(decoded)
  when defined(writeImages):
    newImage(decoded).writeOutputImage(pngSuiteOutputDir, file)

block:
  let
    png8 = decodePng(readFile("tests/fileformats/png/pngsuite/basn2c08.png"))
    png16 = decodePng(readFile("tests/fileformats/png/pngsuite/basn2c16.png"))
    image16 = png16.convertToImage()
  doAssert png8.bitDepth == 8
  doAssert png8.data.len == png8.width * png8.height
  doAssert png8.data16.len == 0
  doAssert png16.bitDepth == 16
  doAssert png16.data.len == 0
  doAssert png16.data16.len == png16.width * png16.height
  doAssert image16.width == png16.width
  doAssert image16.height == png16.height

block:
  let source = newImage(16, 8)
  let encoded = source.encodePng()

  var scaledData = encoded
  let scaled = decodePngScaled(scaledData, 4, 2)
  doAssert scaled.width == 4
  doAssert scaled.height == 2
  doAssert scaledData.len == 0

  var genericData = encoded
  let generic = decodeImageScaled(genericData, 5, 3)
  doAssert generic.width == 5
  doAssert generic.height == 3
  doAssert genericData.len == 0

  var targetData = encoded
  let target = newImage(3, 2)
  doAssert decodeImageScaledInto(targetData, target) == target
  doAssert target.width == 3
  doAssert target.height == 2
  doAssert targetData.len == 0

block:
  for channels in 1 .. 4:
    var data: seq[uint8]
    for x in 0 ..< 16:
      for y in 0 ..< 16:
        var components = newSeq[uint8](channels)
        for i in 0 ..< channels:
          components[i] = (x * 16).uint8
        data.add(components)
    let encoded = encodePng(16, 16, channels, data[0].addr, data.len)

  for file in pngSuiteCorruptedFiles:
    try:
      discard decodePng(readFile(&"tests/fileformats/png/pngsuite/{file}.png"))
      doAssert false
    except PixieError:
      discard

block:
  discard readImage("tests/fileformats/png/trailing_data.png")

block:
  let dimensions =
    decodeImageDimensions(readFile("tests/fileformats/png/mandrill.png"))
  doAssert dimensions.width == 512
  doAssert dimensions.height == 512
