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

const jpgExpectations = [
  # Curated against ImageMagick and Pixie's supported JPEG subset. Files Pixie
  # should fully decode are shouldDecode, decodable-but-unsupported variants are
  # shouldNotCrash, and malformed files that should still be rejected are
  # shouldReject.
  ("138d3b9e0d9fbf641b8135981e597c3a.jpg", shouldNotCrash),
  ("194531363df5b73f59c4c0517422f917.jpg", shouldDecode),
  ("1cbb1bb37d62c44f67374cd451643dc4.jpg", shouldNotCrash),
  ("2183d39878e734cf79b62428b02fafb5.jpg", shouldReject),
  ("21a84b8472f6d18f5bb5c0026e97cfaa.jpg", shouldReject),
  ("21ad703b38e2c350215bb92a849486f3.jpg", shouldDecode),
  ("255015e07b6f9137b53b0f97d67a8aef.jpg", shouldDecode),
  ("28968137f4fc75fbf56f16d7a7a8551a.jpg", shouldReject),
  ("28c74d9284d9836017fd519f6932efd8.jpg", shouldDecode),
  ("2c9e7a1805f8b47630bbb83d21bf8222.jpg", shouldDecode),
  ("316be81dfdeeb942e904feb3a77f4f83.jpg", shouldDecode),
  ("32d08f4a5eb10332506ebedbb9bc7257.jpg", shouldDecode),
  ("3976a754ef0aca80e84e2c403d714579.jpg", shouldDecode),
  ("39f43f280b31152f1d27df3f9d189317.jpg", shouldNotCrash),
  ("3ba6af611cc5467cfdbd5566561b8478.jpg", shouldReject),
  ("3cc4a7fc6481ea3681138da4643f3d16.jpg", shouldNotCrash),
  ("3ea649db8e81a46ca4f92fb3238f78ff.jpg", shouldDecode),
  ("3ef05501315073d9d4e1c6b654d99ac0.jpg", shouldNotCrash),
  ("4085c929e00c446d3fee18b5b20a27f9.jpg", shouldReject),
  ("40bb78b1ac031125a6d8466b374962a8.jpg", shouldDecode),
  ("46e5ac4a62d7a445a7c1fb704fafe05c.jpg", shouldReject),
  ("46f5d9c1b0fe352353688f736e5617b6.jpg", shouldDecode),
  ("4838ece0d3900220d33528ee027289bc.jpg", shouldDecode),
  ("5315c35bbcc28d8eee419028ac9f38e0.jpg", shouldDecode),
  ("5482a54657765056f1a94116a8dbffe7.jpg", shouldNotCrash),
  ("551c2656a4f6f9f5ea7e9945b9081202.jpg", shouldDecode),
  ("5633ed9d0eb700d0093bf85d86a95ebf.jpg", shouldReject),
  ("56d4a1bb53241f7c5ed6ab531320a542.jpg", shouldDecode),
  ("59d3b529c78ac722127c41ba75b3355b.jpg", shouldDecode),
  ("5a43fa2cf9c1e47f0331ef71b928ee55.jpg", shouldReject),
  ("5baad44ca4702949724234e35c5bb341.jpg", shouldDecode),
  ("5bc61724b33e34a6188a817f9f2f8138.jpg", shouldDecode),
  ("5c67195f6993c9f8d0d32d4ffe0d8e62.jpg", shouldDecode),
  ("5dc71b1d868ef137394d3cc23abea65a.jpg", shouldReject),
  ("627c0779eb46b98f751187c5c9f43aa3.jpg", shouldReject),
  ("6903d4538fd33c8fd0ded32cb30d618e.jpg", shouldReject),
  ("6de166ee2a3a60df9017650e2a808408.jpg", shouldReject),
  ("72d091e08c93c9e590360130fa35221b.jpg", shouldDecode),
  ("754664a12e36abff7950e796c906ae39.jpg", shouldReject),
  ("75e4bd7544a85af6438497980b62fba5.jpg", shouldDecode),
  ("786b67badc535fc95a4a76c29a0e0146.jpg", shouldDecode),
  ("7997b6b229f25315d33f5c7085e37500.jpg", shouldDecode),
  ("79f5fc6bca756e1f067c6fc83e18b32e.jpg", shouldDecode),
  ("7acc832f70b2ca62e58a953f3b90fd82.jpg", shouldReject),
  ("7dbf474f80e466e9e25ee46b84166420.jpg", shouldDecode),
  ("7e7cdf7f4ee50b308531313bbf43e0c3.jpg", shouldReject),
  ("8417a305e3b43d5b1bda4ff06a660c54.jpg", shouldReject),
  ("8546907dbe574744d7fea6ca9de1de6b.jpg", shouldDecode),
  ("865db3dd2d380626f16b6f9dc6d62dba.jpg", shouldDecode),
  ("897b8b6d8feb466aa6cad5f512c3fce2.jpg", shouldReject),
  ("8a9cc8eeed66aeb423a91c44111d9450.jpg", shouldDecode),
  ("8e330afbd99ba01b66570ed62fcdc6ab.jpg", shouldReject),
  ("8e5e74dbf9b68a322fbb9512db837329.jpg", shouldDecode),
  ("90e46387f562ca8fa106b51dfcda1dc6.jpg", shouldReject),
  ("96b3e939852157613fa2e48d58fe35fe.jpg", shouldDecode),
  ("9efd60f04cd971daa83d3131e6d6f389.jpg", shouldDecode),
  ("a17806f32b45d63eea5230e7893e1f15.jpg", shouldDecode),
  ("a54f8c866cbef6e6cda858c85d72dfc8.jpg", shouldReject),
  ("a7326ba8f3f4559991126474dd30083d.jpg", shouldNotCrash),
  ("acb1fac4e618f636d415f62496e8b70e.jpg", shouldDecode),
  ("acce3629083f0e348e94fb58f952d3de.jpg", shouldReject),
  ("adcb34b94f4c839bdd29037419a0ee53.jpg", shouldReject),
  ("b0b8914cc5f7a6eff409f16d8cc236c5.jpg", shouldReject),
  ("b4103df93880fc5677c2a081e4bfc712.jpg", shouldDecode),
  ("b5369bcbddca7135a5708c5237ad64e4.jpg", shouldDecode),
  ("b55977028a3a574336966b6536640fc9.jpg", shouldDecode),
  ("ba60305ac83fe3d8ef01da1d9a0ecc79.jpg", shouldDecode),
  ("bd8cf05698aee36b82b4caf58edea442.jpg", shouldReject),
  ("c1ca5583e4bfadc73e7fe9418b6e6bf4.jpg", shouldReject),
  ("c3018ebe53d0046eecb58858ca869a99.jpg", shouldDecode),
  ("c4ced510f44a9bfe85c696c05a7f791d.jpg", shouldReject),
  ("c52ffdd6a0346c4d09271f8ccbdfd5a3.jpg", shouldReject),
  ("c8bc97335529d069a753c67475b8c82c.jpg", shouldReject),
  ("c8c1a5675f82021d92b928a10c597bad.jpg", shouldReject),
  ("cc23dd79637b606cf5ba234a037e17ba.jpg", shouldReject),
  ("cc4ee796d16c9fe68978166c7cd1ae1b.jpg", shouldReject),
  ("ce380515a534e8226209daae00e7b4e8.jpg", shouldReject),
  ("d085a42245996e5750a30ccb48791bcf.jpg", shouldReject),
  ("d15b71b8cebe35a57cc6e996cc09218b.jpg", shouldDecode),
  ("d22db5be7594c17a18a047ca9264ea0a.jpg", shouldDecode),
  ("d3b044a94486cae0224c002800ddd642.jpg", shouldReject),
  ("de4ae285a275bcfe2ac87c0126742552.jpg", shouldReject),
  ("de5884cec093257d239f3b8be3e2f2e5.jpg", shouldDecode),
  ("e18bb52107598f65b81b02be2c6c5124.jpg", shouldReject),
  ("e6d9eca2c7405e13cfb850b7d0ef7476.jpg", shouldReject),
  ("eddea4ef9629be031f750a8ff0b7497c.jpg", shouldReject),
  ("eecb78b937a7c5f04aae2f5b0f5b5acc.jpg", shouldDecode),
  ("ef1f8a057bb6056674fad92f6b8c0acd.jpg", shouldNotCrash),
  ("ef724193653930f52acffa90e6426fd2.jpg", shouldReject),
  ("f006e96f3b27fdfaa075322d759ea2e8.jpg", shouldDecode),
  ("f012a4321f00f12af6b1eee7580ffb9c.jpg", shouldReject),
  ("f1fad47f213bb64c99f714652f30e49e.jpg", shouldReject),
  ("f6419b06a39ff09604343848658b1a41.jpg", shouldDecode),
  ("f6b4389c3cf0f5997b2e5a4b905aea8d.jpg", shouldDecode),
  ("f6d3f522dcb693d9e731d5a0fb4e1393.jpg", shouldDecode),
  ("f8e19feecd246156b5d7e79efc455e99.jpg", shouldReject),
  ("fd44dc63fa7bdd12ee34fc602231ef02.jpg", shouldDecode),
  ("fddcfc778ada60229380c2493fc4c243.jpg", shouldReject)
]

proc expectedFor(kind, path: string): Expectation =
  let fileName = path.splitPath.tail

  if kind == "gif":
    for (name, expectation) in gifExpectations:
      if fileName == name:
        return expectation
    raise newException(ValueError, "Missing GIF expectation for " & fileName)

  if kind == "jpg":
    for (name, expectation) in jpgExpectations:
      if fileName == name:
        return expectation
    raise newException(ValueError, "Missing JPG expectation for " & fileName)

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
