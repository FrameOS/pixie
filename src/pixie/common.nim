import bumpy, chroma, vmath

type
  PixieError* = object of CatchableError ## Raised if an operation fails.

  BlendMode* = enum
    NormalBlend
    DarkenBlend
    MultiplyBlend
    # BlendLinearBurn
    ColorBurnBlend
    LightenBlend
    ScreenBlend
    # BlendLinearDodge
    ColorDodgeBlend
    OverlayBlend
    SoftLightBlend
    HardLightBlend
    DifferenceBlend
    ExclusionBlend
    HueBlend
    SaturationBlend
    ColorBlend
    LuminosityBlend

    MaskBlend         ## Special blend mode that is used for masking
    OverwriteBlend    ## Special blend mode that just copies pixels
    SubtractMaskBlend ## Inverse mask
    ExcludeMaskBlend

  ImageDimensions* = object
    width*, height*: int

  ScaledDecodeFit* = enum
    ## How a scaled decode maps the source onto the target image.
    fitStretch ## fill the whole target, ignoring aspect ratio
    fitCover   ## fill the whole target, cropping the source centered
    fitContain ## fit the whole source centered, leaving target borders untouched

  Image* = ref object
    ## Image object that holds bitmap data in premultiplied alpha RGBA format.
    ##
    ## An image either **owns** its pixels or is a **view** into another
    ## image's. A view shares the owner's buffer and addresses a rectangle
    ## inside it, so handing a caller a sub-region costs nothing and writes
    ## through to the original — which is what lets a tiled render draw its
    ## cells in place instead of copying each one out and back.
    ##
    ## `stride` is the distance between rows in the shared buffer, so it equals
    ## `width` for an owner and the owner's `width` for a view. Everything that
    ## addresses pixels through `dataIndex` is therefore correct for both.
    ## Anything that walks the buffer flat, assuming rows are contiguous across
    ## the whole image, is correct only for an owner — see `isContiguous`.
    width*, height*: int
    stride*: int  ## elements between vertically adjacent pixels
    origin*: int  ## index of (0, 0) within the shared buffer
    storage: seq[ColorRGBX] ## owned pixels; empty for a view
    root: Image             ## the owner whose buffer this views; nil if owner
    pixels: ptr UncheckedArray[ColorRGBX] ## the buffer, owned or borrowed

  ImageSourceProc* = proc(
    dst: pointer, maxBytes: int
  ): int {.gcsafe, raises: [].}
    ## Pull callback for streamed decodes: fill `dst` with up to `maxBytes`
    ## sequential input bytes, returning how many were written (<= 0 on EOF
    ## or read error — the decode then fails with a catchable PixieError).

proc scaledFitRects*(
  srcWidth, srcHeight, targetWidth, targetHeight: int, fit: ScaledDecodeFit
): tuple[srcX, srcY, srcW, srcH, dstX, dstY, dstW, dstH: int] =
  ## Computes the source crop and target placement rectangles for a fit mode.
  result = (0, 0, srcWidth, srcHeight, 0, 0, targetWidth, targetHeight)
  case fit
  of fitStretch:
    discard
  of fitCover:
    if srcWidth.int64 * targetHeight.int64 >
        targetWidth.int64 * srcHeight.int64:
      let cropW = max(1, (
        srcHeight.int64 * targetWidth.int64 div
        max(1'i64, targetHeight.int64)).int)
      result.srcX = (srcWidth - cropW) div 2
      result.srcW = cropW
    else:
      let cropH = max(1, (
        srcWidth.int64 * targetHeight.int64 div
        max(1'i64, targetWidth.int64)).int)
      result.srcY = (srcHeight - cropH) div 2
      result.srcH = cropH
  of fitContain:
    if srcWidth.int64 * targetHeight.int64 >
        targetWidth.int64 * srcHeight.int64:
      let fitH = max(1, (
        targetWidth.int64 * srcHeight.int64 div
        max(1'i64, srcWidth.int64)).int)
      result.dstY = (targetHeight - fitH) div 2
      result.dstH = fitH
    else:
      let fitW = max(1, (
        targetHeight.int64 * srcWidth.int64 div
        max(1'i64, srcHeight.int64)).int)
      result.dstX = (targetWidth - fitW) div 2
      result.dstW = fitW

template data*(image: Image): ptr UncheckedArray[ColorRGBX] =
  ## The pixels this image addresses — its own, or its owner's when it is a
  ## view. Indexed with `dataIndex`, never with a flat running counter unless
  ## `isContiguous` says that is safe.
  image.pixels

template dataIndex*(image: Image, x, y: int): int =
  image.origin + image.stride * y + x

template isContiguous*(image: Image): bool =
  ## True when the image's rows sit back to back in the buffer, which is what a
  ## whole-image flat loop needs. Always true for an owner; true for a view only
  ## when it is full width.
  image.stride == image.width

template forEachSpan*(image: Image, body: untyped) =
  ## Runs `body` over every run of pixels that IS contiguous in the buffer,
  ## injecting `spanStart` (an index into `image.data`) and `spanLen`.
  ##
  ## An image that owns its pixels is one span, so a whole-image operation
  ## written this way costs exactly what it did before the views existed — one
  ## call, one loop, the same SIMD. A view is one span per row. This is the
  ## seam that lets flat operations stay fast and become correct at once.
  block:
    if image.stride == image.width:
      let spanStart {.inject.} = image.origin
      let spanLen {.inject.} = image.width * image.height
      body
    else:
      for spanRow in 0 ..< image.height:
        let spanStart {.inject.} = image.origin + image.stride * spanRow
        let spanLen {.inject.} = image.width
        body

template dataLen*(image: Image): int =
  ## Number of pixels the image addresses. Only the extent of a flat walk when
  ## `isContiguous`.
  image.width * image.height

proc newImage*(width, height: int): Image {.raises: [PixieError].} =
  ## Creates a new image with the parameter dimensions.
  if width <= 0 or height <= 0:
    raise newException(PixieError, "Image width and height must be > 0")

  result = Image()
  result.width = width
  result.height = height
  result.stride = width
  result.origin = 0
  result.storage = newSeq[ColorRGBX](width * height)
  result.pixels = cast[ptr UncheckedArray[ColorRGBX]](result.storage[0].addr)

proc newImageFrom*(
  width, height: int, data: sink seq[ColorRGBX]
): Image {.raises: [PixieError].} =
  ## Wraps an existing buffer as an image that owns it, without copying.
  ##
  ## Decoders build their pixels in a seq and hand it over; that move is worth
  ## keeping, so this exists rather than making them copy into a fresh image.
  if width <= 0 or height <= 0:
    raise newException(PixieError, "Image width and height must be > 0")
  if data.len < width * height:
    raise newException(PixieError, "Buffer is too small for " & $width & "x" & $height)
  result = Image()
  result.width = width
  result.height = height
  result.stride = width
  result.origin = 0
  result.storage = data
  result.pixels = cast[ptr UncheckedArray[ColorRGBX]](result.storage[0].addr)

proc toContiguousSeq*(image: Image): seq[ColorRGBX] {.raises: [].} =
  ## The image's pixels as a packed, owned buffer, rows back to back.
  ##
  ## For encoders and anything else that needs to hand a plain array to a
  ## library. It is a copy on purpose: `image.data` is a pointer now, so
  ## `var copy = image.data` aliases rather than copies, and a caller that then
  ## mutates `copy` would be scribbling on the image it was asked to read.
  result = newSeq[ColorRGBX](image.width * image.height)
  if image.width * image.height > 0:
    for y in 0 ..< image.height:
      copyMem(
        result[y * image.width].addr,
        image.data[image.dataIndex(0, y)].addr,
        image.width * 4
      )

proc newImageFromUnchecked*(
  width, height: int, data: sink seq[ColorRGBX]
): Image {.raises: [].} =
  ## `newImageFrom` for callers whose dimensions are already validated and
  ## whose signature promises not to raise — the decoders, which checked the
  ## header long before they got here. Wrong arguments are a programming error,
  ## not a malformed file, so they assert rather than raise.
  doAssert width > 0 and height > 0
  doAssert data.len >= width * height
  result = Image()
  result.width = width
  result.height = height
  result.stride = width
  result.origin = 0
  result.storage = data
  result.pixels = cast[ptr UncheckedArray[ColorRGBX]](result.storage[0].addr)

proc view*(image: Image, x, y, w, h: int): Image {.raises: [PixieError].} =
  ## A window onto part of `image`, sharing its pixels. Writes through.
  ##
  ## Views of views are flattened onto the original owner, so nesting costs one
  ## object and no extra indirection however deep it goes.
  if w <= 0 or h <= 0:
    raise newException(PixieError, "View width and height must be > 0")
  if x < 0 or y < 0 or x + w > image.width or y + h > image.height:
    raise newException(PixieError, "View " & $w & "x" & $h & " at " & $x & "," &
      $y & " does not fit inside " & $image.width & "x" & $image.height)
  result = Image()
  result.width = w
  result.height = h
  result.stride = image.stride
  result.origin = image.dataIndex(x, y)
  result.root = if image.root.isNil: image else: image.root
  result.pixels = image.pixels

template isView*(image: Image): bool =
  ## True when the image borrows another's pixels rather than owning them.
  not image.root.isNil

proc copy*(image: Image): Image {.raises: [].} =
  ## Copies the image data into a new image. A view copies out, so the result
  ## always owns its pixels.
  result = Image()
  result.width = image.width
  result.height = image.height
  result.stride = image.width
  result.origin = 0
  result.storage = newSeq[ColorRGBX](image.width * image.height)
  result.pixels = cast[ptr UncheckedArray[ColorRGBX]](result.storage[0].addr)
  for y in 0 ..< image.height:
    copyMem(
      result.pixels[result.dataIndex(0, y)].addr,
      image.pixels[image.dataIndex(0, y)].addr,
      image.width * 4
    )

proc mix*(a, b: ColorRGBX, t: float32): ColorRGBX {.inline, raises: [].} =
  ## Linearly interpolate between a and b using t.
  let x = round(t * 255).uint32
  result.r = ((a.r.uint32 * (255 - x) + b.r.uint32 * x + 127) div 255).uint8
  result.g = ((a.g.uint32 * (255 - x) + b.g.uint32 * x + 127) div 255).uint8
  result.b = ((a.b.uint32 * (255 - x) + b.b.uint32 * x + 127) div 255).uint8
  result.a = ((a.a.uint32 * (255 - x) + b.a.uint32 * x + 127) div 255).uint8

proc `*`*(color: ColorRGBX, opacity: float32): ColorRGBX {.raises: [].} =
  if opacity == 0:
    rgbx(0, 0, 0, 0)
  else:
    let
      x = round(opacity * 255).uint32
      r = ((color.r * x + 127) div 255).uint8
      g = ((color.g * x + 127) div 255).uint8
      b = ((color.b * x + 127) div 255).uint8
      a = ((color.a * x + 127) div 255).uint8
    rgbx(r, g, b, a)

proc `*`*(rgbx: ColorRGBX, opacity: uint8): ColorRGBX {.inline.} =
  if opacity == 0:
    discard
  elif opacity == 255:
    result = rgbx
  else:
    result = rgbx(
      ((rgbx.r.uint32 * opacity + 127) div 255).uint8,
      ((rgbx.g.uint32 * opacity + 127) div 255).uint8,
      ((rgbx.b.uint32 * opacity + 127) div 255).uint8,
      ((rgbx.a.uint32 * opacity + 127) div 255).uint8
    )

proc snapToPixels*(rect: Rect): Rect {.raises: [].} =
  let
    xMin = rect.x
    xMax = rect.x + rect.w
    yMin = rect.y
    yMax = rect.y + rect.h
  result.x = floor(xMin)
  result.w = ceil(xMax) - result.x
  result.y = floor(yMin)
  result.h = ceil(yMax) - result.y
