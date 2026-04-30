import pixie, pixie/fileformats/ppm

block:
  for format in @["p3", "p6"]:
    let
      path = "tests/fileformats/ppm/feep." & $format & ".master.ppm"
      image = decodePpm(readFile(path))
      dimensions = decodePpmDimensions(readFile(path))
    writeFile("tests/fileformats/ppm/feep." & $format & ".ppm", encodePpm(image))
    doAssert image.width == dimensions.width
    doAssert image.height == dimensions.height

block:
  let
    path = "tests/fileformats/ppm/feep.p3.hidepth.master.ppm"
    image = decodePpm(readFile(path))
    dimensions = decodePpmDimensions(readFile(path))
  writeFile("tests/fileformats/ppm/feep.p3.hidepth.ppm", encodePpm(image))
  doAssert image.width == dimensions.width
  doAssert image.height == dimensions.height

  # produced output should be identical to P6 master
  let p6Master = readFile("tests/fileformats/ppm/feep.p6.master.ppm")
  for image in @["p3", "p6", "p3.hidepth"]:
    doAssert readFile("tests/fileformats/ppm/feep." & $image & ".ppm") == p6Master

block:
  let payload = "P6\n10 10\n255\n" & "\x12\x34\x56"

  doAssertRaises PixieError:
    discard decodeImage(payload)
