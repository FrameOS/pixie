import pixie, pixie/fileformats/tiff

let
  t = decodeTiff(readFile("tests/fileformats/tiff/pc260001.tif"))
  image = newImage(t)
# image.writeFile("tests/fileformats/tiff/pc260001.png")

block:
  proc addLe16(data: var string, value: int) =
    data.add(char(value and 0xff))
    data.add(char((value shr 8) and 0xff))

  proc addLe32(data: var string, value: int) =
    data.add(char(value and 0xff))
    data.add(char((value shr 8) and 0xff))
    data.add(char((value shr 16) and 0xff))
    data.add(char((value shr 24) and 0xff))

  proc addIfdEntry(
    data: var string,
    tag, fieldType, numValues, valueOrOffset: int
  ) =
    data.addLe16(tag)
    data.addLe16(fieldType)
    data.addLe32(numValues)
    data.addLe32(valueOrOffset)

  const
    ifdOffset = 8
    entryCount = 9
    colorMapOffset = ifdOffset + 2 + entryCount * 12 + 4
    pixelDataOffset = colorMapOffset + 6

  var payload = ""
  payload.add("II")
  payload.addLe16(42)
  payload.addLe32(ifdOffset)
  payload.addLe16(entryCount)
  payload.addIfdEntry(0x0100, 4, 1, 1) # ImageWidth
  payload.addIfdEntry(0x0101, 4, 1, 1) # ImageLength
  payload.addIfdEntry(0x0102, 3, 1, 8) # BitsPerSample
  payload.addIfdEntry(0x0103, 3, 1, 1) # Compression = none
  payload.addIfdEntry(0x0106, 3, 1, 3) # PhotometricInterpretation = palette
  payload.addIfdEntry(0x0111, 4, 1, pixelDataOffset)
  payload.addIfdEntry(0x0116, 4, 1, 1) # RowsPerStrip
  payload.addIfdEntry(0x0117, 4, 1, 1) # StripByteCounts
  payload.addIfdEntry(0x0140, 3, 3, colorMapOffset)
  payload.addLe32(0)
  payload.addLe16(0)
  payload.addLe16(0)
  payload.addLe16(0)
  payload.add(char(0x01))

  doAssertRaises PixieError:
    discard decodeTiff(payload)
