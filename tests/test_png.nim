import pixie, pixie/fileformats/png, pixie/decodebudget, pngsuite, strformat, strutils, crunchy, flatty/binny

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

block: # streamed scanlines keep canvas-sized decodes within tight budgets
  let source = newImage(480, 800)
  for y in 0 ..< source.height:
    for x in 0 ..< source.width:
      source.unsafe[x, y] = rgbx(uint8(x mod 256), uint8(y mod 256), uint8((x + y) mod 256), 255)
  let encoded = encodePng(source.width, source.height, 4, source.data[0].addr, source.data.len * 4)

  # Full decode plan is pixels + fixed streaming overhead (~1.6MB);
  # a 2MB budget must accept it
  setDecodeBudgetBytes(2 * 1024 * 1024)
  let decoded = decodePng(encoded).convertToImage()
  doAssert decoded.width == 480
  doAssert decoded.height == 800
  doAssert decoded[123, 456] == source[123, 456]

  # A 1MB budget cannot hold the pixels themselves and must reject
  setDecodeBudgetBytes(1024 * 1024)
  try:
    discard decodePng(encoded)
    doAssert false
  except PixieError as e:
    doAssert "memory budget" in e.msg

  # Scaled decode into a small target never allocates the full pixel
  # buffer: a 256KB budget suffices for a 480x800 source
  setDecodeBudgetBytes(256 * 1024)
  let target = newImage(96, 60)
  decodePngScaledInto(encoded, target, fitStretch)
  doAssert target[48, 30] == source[240, 400]
  setDecodeBudgetBytes(0)

block: # streamed scaled decodes match the buffered fillImage path
  let source = newImage(123, 77)
  for y in 0 ..< source.height:
    for x in 0 ..< source.width:
      source.unsafe[x, y] = rgbx(uint8((x * 7) mod 256), uint8((y * 5) mod 256), uint8((x + y) mod 256), 255)
  let encoded = encodePng(source.width, source.height, 4, source.data[0].addr, source.data.len * 4)
  for fit in [fitStretch, fitCover, fitContain]:
    for (w, h) in [(50, 40), (123, 77), (300, 90), (33, 200)]:
      let streamed = decodePngScaled(encoded, w, h, fit)
      let buffered = decodePng(encoded).convertToImage(w, h, fit)
      doAssert streamed.width == buffered.width
      doAssert streamed.height == buffered.height
      for i in 0 ..< streamed.data.len:
        doAssert streamed.data[i] == buffered.data[i],
          "pixel mismatch at " & $i & " fit " & $fit & " " & $w & "x" & $h

block: # multi-IDAT PNGs decode without concatenating the compressed stream
  # Real-world encoders split compressed data across hundreds of IDAT
  # chunks (libpng defaults to 8K). The inflater consumes them as segments;
  # re-chunk a PNG's IDAT at awkward sizes — including 1-byte chunks that
  # split the zlib header — and require identical output.
  proc rechunkIdat(encoded: string, chunkSize: int): string =
    ## Rewrites a PNG so its IDAT payload is split into chunkSize-byte IDATs.
    var idatData = ""
    result = encoded[0 ..< 8] # signature
    var pos = 8
    while pos < encoded.len:
      let
        chunkLen = int(encoded.readUint32(pos).swap())
        chunkType = encoded[pos + 4 ..< pos + 8]
    # collect IDAT payloads, copy everything else verbatim (before IEND)
      if chunkType == "IDAT":
        idatData.add(encoded[pos + 8 ..< pos + 8 + chunkLen])
      elif chunkType == "IEND":
        break
      else:
        result.add(encoded[pos ..< pos + 12 + chunkLen])
      pos += 12 + chunkLen

    var off = 0
    while off < idatData.len:
      let n = min(chunkSize, idatData.len - off)
      var chunk = ""
      chunk.addUint32(n.uint32.swap())
      chunk.add("IDAT")
      chunk.add(idatData[off ..< off + n])
      chunk.addUint32(crc32(chunk[chunk.len - n - 4].addr, n + 4).swap())
      result.add(chunk)
      off += n

    var iend = ""
    iend.addUint32(0.uint32.swap())
    iend.add("IEND")
    iend.addUint32(crc32(iend[iend.len - 4].addr, 4).swap())
    result.add(iend)

  let source = newImage(101, 53)
  for y in 0 ..< source.height:
    for x in 0 ..< source.width:
      source.unsafe[x, y] = rgbx(uint8((x * 3) mod 256), uint8((y * 11) mod 256), uint8((x * y) mod 256), 255)
  let encoded = encodePng(source.width, source.height, 4, source.data[0].addr, source.data.len * 4)
  let reference = decodePng(encoded).convertToImage()

  for chunkSize in [1, 2, 3, 7, 64, 8192, 1 shl 30]:
    let rechunked = rechunkIdat(encoded, chunkSize)
    let decoded = decodePng(rechunked).convertToImage()
    doAssert decoded.width == reference.width and decoded.height == reference.height
    for i in 0 ..< decoded.data.len:
      doAssert decoded.data[i] == reference.data[i],
        "pixel mismatch at " & $i & " with IDAT chunk size " & $chunkSize

    let target = newImage(48, 20)
    decodePngScaledInto(rechunked, target, fitStretch)
    let expected = decodePng(encoded).convertToImage(48, 20, fitStretch)
    for i in 0 ..< target.data.len:
      doAssert target.data[i] == expected.data[i],
        "scaled pixel mismatch at " & $i & " with IDAT chunk size " & $chunkSize
