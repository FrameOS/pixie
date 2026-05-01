import algorithm, os, osproc, strformat, strutils
import pixie/common, pixie/fileformats/gif, pixie/fileformats/jpeg,
  pixie/fileformats/png, pixie/fileformats/tiff

const imageTestSuitePath = "../imagetestsuite"

type
  Expectation = enum
    shouldDecode
    shouldReject
    shouldNotCrash

  RunStatus = enum
    decoded
    rejected
    failed

  RunResult = object
    status: RunStatus
    message: string

  TestStats = object
    total, passed: int
    failures: seq[string]

const gifExpectations = [
  # Based on the upstream GIFTestSuite notes. Most files are malformed on
  # purpose and should be rejected cleanly instead of decoded.
  ("0646caeb9b9161c777f117007921a687.gif", shouldReject),
  ("243d9798466d64aba0acaa41f980bea6.gif", shouldReject),
  ("2b5bc31d84703bfb9f371925f0e3e57d.gif", shouldReject),
  ("55abb3cc464305dd554171c3d44cb61f.gif", shouldReject),
  ("5f09a896c191db3fa7ea6bdd5ebe9485.gif", shouldReject),
  ("6d939393058de0579fca1bbf10ecff25.gif", shouldReject),
  ("7092f253998c1b6b869707ad7ae92854.gif", shouldReject),
  ("9f8f6046eaf9ffa2d9c5d6db05c5f881.gif", shouldReject),
  ("adaf0da1764aafb7039440dbe098569b.gif", shouldReject),
  ("adf6f850b13dff73ebb22862c6ab028b.gif", shouldReject),
  ("bc7af0616c4ae99144c8600e7b39beea.gif", shouldReject),
  ("ce774930ac70449f38a18789c70095b8.gif", shouldReject),
  ("d5a0175c07418852152ef33a886a5029.gif", shouldReject),
  ("e34116d68f49c7852b362ec72a636df5.gif", shouldReject),
  ("e6aa0c45a13dd7fc94f7b5451bd89bf4.gif", shouldDecode),
  ("ea754e040929b7f9c157efc88c4d0eaf.gif", shouldReject),
  ("ee6d1133f9264dc6467990e53d0bf104.gif", shouldReject),
  # Pixie intentionally tolerates this extension-order issue.
  ("f617c7af7f36296a37ddb419b828099c.gif", shouldDecode),
  ("f88b6907ee086c4c8ac4b8c395748c49.gif", shouldReject),
  ("fc3e2b992c559055267e26dc23e484c0.gif", shouldReject)
]

proc expectedFor(kind, path: string): Expectation =
  if kind == "gif":
    let fileName = path.splitPath.tail
    for (name, expectation) in gifExpectations:
      if fileName == name:
        return expectation
    raise newException(ValueError, "Missing GIF expectation for " & fileName)

  shouldDecode

proc sortedFiles(dir, pattern: string): seq[string] =
  for path in walkFiles(dir / pattern):
    result.add(path)
  result.sort()

proc checkDimensions(
  stats: var TestStats,
  path: string,
  width, height: int,
  dimensions: ImageDimensions
) =
  if width != dimensions.width or height != dimensions.height:
    stats.failures.add(&"{path}: decoded {width}x{height}, dimensions " &
      &"{dimensions.width}x{dimensions.height}")

proc checkGif(stats: var TestStats, path: string) =
  let data = readFile(path)
  let
    gif = decodeGif(data)
    image = newImage(gif)
    dimensions = decodeGifDimensions(data)
  stats.checkDimensions(path, image.width, image.height, dimensions)

proc checkJpeg(stats: var TestStats, path: string) =
  let data = readFile(path)
  let
    image = decodeJpeg(data)
    dimensions = decodeJpegDimensions(data)
  stats.checkDimensions(path, image.width, image.height, dimensions)

proc checkPng(stats: var TestStats, path: string) =
  let data = readFile(path)
  let
    dimensions = decodePngDimensions(data)
    image = decodePng(data).convertToImage()
  stats.checkDimensions(path, image.width, image.height, dimensions)

proc checkTiff(stats: var TestStats, path: string) =
  let
    tiff = decodeTiff(readFile(path))
    image = newImage(tiff)
  if image.width != tiff.width or image.height != tiff.height:
    stats.failures.add(&"{path}: decoded {image.width}x{image.height}, " &
      &"TIFF {tiff.width}x{tiff.height}")

proc checkOne(kind, path: string) =
  var stats: TestStats
  case kind
  of "gif":
    stats.checkGif(path)
  of "jpg":
    stats.checkJpeg(path)
  of "png":
    stats.checkPng(path)
  of "tif":
    stats.checkTiff(path)
  else:
    raise newException(ValueError, "Unknown image test kind " & kind)

  if stats.failures.len > 0:
    raise newException(ValueError, stats.failures.join("; "))

proc lastNonEmptyLine(text: string): string =
  for line in text.splitLines:
    let line = line.strip()
    if line.len > 0:
      result = line

proc runOne(kind, path: string): RunResult =
  let
    cmd = quoteShell(getAppFilename()) & " " & quoteShell(kind) & " " &
      quoteShell(path)
    (output, exitCode) = execCmdEx(cmd)

  let message = output.lastNonEmptyLine()
  if exitCode == 0:
    result.status = decoded
  elif message.startsWith("PixieError:"):
    result.status = rejected
    result.message = message
  else:
    result.status = failed
    if message.len > 0:
      result.message = message
    else:
      result.message = "exit code " & $exitCode

proc failedExpectation(
  path: string,
  expectation: Expectation,
  runResult: RunResult
): string =
  case expectation
  of shouldDecode:
    case runResult.status
    of decoded:
      discard
    of rejected:
      result = &"{path}: expected decode, rejected with {runResult.message}"
    of failed:
      result = &"{path}: expected decode, failed with {runResult.message}"

  of shouldReject:
    case runResult.status
    of decoded:
      result = &"{path}: decoded, expected PixieError"
    of rejected:
      discard
    of failed:
      result = &"{path}: expected PixieError, failed with {runResult.message}"

  of shouldNotCrash:
    if runResult.status == failed:
      result = &"{path}: expected decode or PixieError, failed with " &
        runResult.message

proc checkFiles(
  stats: var TestStats,
  dir, pattern, label: string,
  kind: string
) =
  let files = sortedFiles(imageTestSuitePath / dir, pattern)
  let passedBefore = stats.passed
  let failuresBefore = stats.failures.len
  echo &"{label}: {files.len} files"

  for path in files:
    inc stats.total
    let
      expectation = expectedFor(kind, path)
      runResult = runOne(kind, path)
      failure = failedExpectation(path, expectation, runResult)
    if failure.len == 0:
      inc stats.passed
    else:
      stats.failures.add(failure)

  echo &"{label}: {stats.passed - passedBefore}/{files.len} passed, " &
    &"{stats.failures.len - failuresBefore} failed"

if paramCount() == 2:
  try:
    checkOne(paramStr(1), paramStr(2))
  except Exception as exc:
    echo &"{exc.name}: {exc.msg}"
    quit(1)
  quit(0)

if not dirExists(imageTestSuitePath):
  echo &"Skipping imagetestsuite: {imageTestSuitePath} was not found"
else:
  var stats: TestStats
  stats.checkFiles("gif", "*.gif", "GIF", "gif")
  stats.checkFiles("jpg", "*.jpg", "JPG", "jpg")
  stats.checkFiles("png", "*.png", "PNG", "png")
  stats.checkFiles("tif", "*.tif", "TIF", "tif")

  echo &"imagetestsuite: {stats.passed}/{stats.total} passed"

  if stats.failures.len > 0:
    echo &"Failures ({stats.failures.len}):"
    for failure in stats.failures:
      echo "  " & failure
    quit(1)
