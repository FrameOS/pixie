## Runtime memory budget for image decoding.
##
## Decoders consult `decodeBudgetBytes` before allocating image-sized
## buffers (coefficient blocks, channel masks, inflate output, pixel seqs)
## and raise a catchable PixieError when a decode would exceed it. The
## budget covers decode *intermediates plus output* for a single decode
## call, not process-wide usage.
##
## 0 means unlimited (upstream pixie behaviour). Embedded builds default
## to a conservative budget; hosts default to unlimited until the
## application calls `setDecodeBudgetBytes` with a live value derived from
## available memory.

when defined(frameosEmbedded):
  const defaultDecodeBudgetBytes = 10 * 1024 * 1024
else:
  const defaultDecodeBudgetBytes = 0

var decodeBudget {.threadvar.}: int
var decodeBudgetInitialized {.threadvar.}: bool

proc decodeBudgetBytes*(): int {.inline, raises: [].} =
  ## Current per-decode memory budget in bytes; 0 = unlimited.
  if not decodeBudgetInitialized:
    decodeBudget = defaultDecodeBudgetBytes
    decodeBudgetInitialized = true
  decodeBudget

proc setDecodeBudgetBytes*(bytes: int) {.raises: [].} =
  ## Sets the per-decode memory budget; 0 = unlimited. Refresh this from
  ## live available memory before heavy decodes for best results.
  decodeBudget = max(0, bytes)
  decodeBudgetInitialized = true

proc overDecodeBudget*(bytes: int64): bool {.inline, raises: [].} =
  ## True when an allocation plan of `bytes` exceeds the current budget.
  let budget = decodeBudgetBytes()
  budget > 0 and bytes > budget.int64
