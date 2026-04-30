import os, pixie, pixie/fileformats/bmp

proc addLe16(data: var string, value: int) =
  data.add(char(value and 0xff))
  data.add(char((value shr 8) and 0xff))

proc addLe32(data: var string, value: int) =
  data.add(char(value and 0xff))
  data.add(char((value shr 8) and 0xff))
  data.add(char((value shr 16) and 0xff))
  data.add(char((value shr 24) and 0xff))

proc makeIndexedBmp(bits: int, pixelData: string): string =
  let
    paletteEntries = 1 shl bits
    pixelDataOffset = 14 + 40 + paletteEntries * 4
    fileSize = pixelDataOffset + pixelData.len

  result.add("BM")
  result.addLe32(fileSize)
  result.addLe16(0)
  result.addLe16(0)
  result.addLe32(pixelDataOffset)
  result.addLe32(40) # BITMAPINFOHEADER
  result.addLe32(1) # Width
  result.addLe32(1) # Height
  result.addLe16(1) # Planes
  result.addLe16(bits)
  result.addLe32(0) # BI_RGB
  result.addLe32(pixelData.len)
  result.addLe32(0)
  result.addLe32(0)
  result.addLe32(0) # clrUsed = 0 means use the default palette size.
  result.addLe32(0)

  for i in 0 ..< paletteEntries:
    if i == paletteEntries - 1:
      result.add("\xff\xff\xff\x00")
    else:
      result.add("\x00\x00\x00\x00")

  result.add(pixelData)

# block:
#   var image = newImage(4, 2)

#   image[0, 0] = rgba(0, 0, 255, 255)
#   image[1, 0] = rgba(0, 255, 0, 255)
#   image[2, 0] = rgba(255, 0, 0, 255)
#   image[3, 0] = rgba(255, 255, 255, 255)

#   image[0, 1] = rgba(0, 0, 255, 127)
#   image[1, 1] = rgba(0, 255, 0, 127)
#   image[2, 1] = rgba(255, 0, 0, 127)
#   image[3, 1] = rgba(255, 255, 255, 127)

#   writeFile("tests/fileformats/bmp/test4x2.bmp", encodeBmp(image))

#   var image2 = decodeBmp(encodeBmp(image))
#   doAssert image2.width == image.width
#   doAssert image2.height == image.height
#   doAssert image2.data == image.data

# block:
#   var image = newImage(16, 16)
#   image.fill(rgba(255, 0, 0, 127))
#   writeFile("tests/fileformats/bmp/test16x16.bmp", encodeBmp(image))

#   var image2 = decodeBmp(encodeBmp(image))
#   doAssert image2.width == image.width
#   doAssert image2.height == image.height
#   doAssert image2.data == image.data

block:
  for bits in [32, 24]:
    let
      path = "tests/fileformats/bmp/knight." & $bits & ".master.bmp"
      image = decodeBmp(readFile(path))
    writeFile("tests/fileformats/bmp/knight." & $bits & ".bmp", encodeBmp(image))

block:
  for fixture in [(1, "\x80\x00\x00\x00"), (4, "\xf0\x00\x00\x00")]:
    let image = decodeBmp(makeIndexedBmp(fixture[0], fixture[1]))
    doAssert image.width == 1
    doAssert image.height == 1
    doAssert image.data[0] == rgbx(255, 255, 255, 255)

block:
  let image = decodeBmp(readFile(
    "tests/fileformats/bmp/rgb.24.master.bmp"
  ))
  writeFile("tests/fileformats/bmp/rgb.24.bmp", encodeBmp(image))

block:
  for file in walkFiles("tests/fileformats/bmp/bmpsuite/*"):
    # echo file
    let
      image = decodeBmp(readFile(file))
      dimensions = decodeBmpDimensions(readFile(file))
    #image.writeFile(file.replace("bmpsuite", "output") & ".png")
    doAssert image.width == dimensions.width
    doAssert image.height == dimensions.height

block:
  let image = newImage(100, 100)
  image.fill(color(1, 0, 0, 1))

  let
    encoded = encodeDib(image)
    decoded = decodeDib(encoded.cstring, encoded.len, true)

  doAssert image.data == decoded.data
