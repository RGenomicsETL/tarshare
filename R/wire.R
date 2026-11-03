# Wire format between shared_cache(<url>) clients and shared_serve().
#
# Frames use the ducknng v1 envelope (RGenomicsETL/ducknng, docs/protocol.md),
# little-endian: version u8 = 1, type u8, control u32 (semantic flags in the
# low 24 bits, status in the high byte), name length u32, error length u32,
# payload length u64, then the method name, the error text and the payload.
# Error frames carry a nonzero status and nonempty error text; other frames
# carry neither.
#
# A tarshare payload is control text, "name<TAB>value" lines, optionally
# followed by one empty line and a body (a manifest, or raw chunk bytes).
# Neither side ever deserializes an R object it receives.

shared_wire_types <- c(manifest = 0L, call = 1L, result = 2L, error = 3L, event = 4L)
shared_wire_status <- c(ok = 0L, invalid = 1L, not_found = 2L, busy = 3L,
                        internal = 6L, unauthorized = 9L)

shared_le <- function(x, n) as.raw(floor(x / 256^(seq_len(n) - 1L)) %% 256)
shared_le_read <- function(bytes) sum(as.numeric(bytes) * 256^(seq_along(bytes) - 1L))

shared_frame <- function(type, name = "", payload = raw(), status = 0L, error = "") {
  name <- charToRaw(enc2utf8(name))
  error <- charToRaw(enc2utf8(error))
  c(as.raw(1L), as.raw(shared_wire_types[[type]]),
    shared_le(status * 2^24, 4L), shared_le(length(name), 4L),
    shared_le(length(error), 4L), shared_le(length(payload), 8L),
    name, error, payload)
}

shared_frame_error <- function(status, error) {
  shared_frame("error", payload = raw(), status = shared_wire_status[[status]],
               error = error)
}

# Returns NULL for anything that is not a well-formed v1 frame.
shared_frame_read <- function(bytes) {
  if (!is.raw(bytes) || length(bytes) < 22L || bytes[[1L]] != as.raw(1L)) return(NULL)
  type <- as.integer(bytes[[2L]])
  control <- shared_le_read(bytes[3:6])
  name_len <- shared_le_read(bytes[7:10])
  error_len <- shared_le_read(bytes[11:14])
  payload_len <- shared_le_read(bytes[15:22])
  if (type > 4L || name_len > 128 || 22 + name_len + error_len + payload_len != length(bytes)) {
    return(NULL)
  }
  status <- control %/% 2^24
  at <- 22L
  take <- function(n) {
    out <- if (n > 0) bytes[at + seq_len(n)] else raw()
    at <<- at + n
    out
  }
  name <- rawToChar(take(name_len))
  error <- rawToChar(take(error_len))
  Encoding(error) <- "UTF-8"
  payload <- take(payload_len)
  if (if (type == 3L) status == 0 || error_len == 0 else status != 0 || error_len != 0) {
    return(NULL)
  }
  list(type = names(shared_wire_types)[shared_wire_types == type], name = name,
       status = names(shared_wire_status)[match(status, shared_wire_status)],
       error = error, payload = payload)
}

shared_wire_value <- function(x) {
  x <- enc2utf8(as.character(x))
  if (length(x) != 1L || is.na(x) || grepl("[\t\n\r]", x)) {
    stop("Store fields must be single strings without tabs or line breaks.", call. = FALSE)
  }
  x
}

shared_payload <- function(fields = list(), body = NULL) {
  text <- paste0(names(fields), "\t", vapply(fields, shared_wire_value, character(1)),
                 collapse = "\n")
  out <- charToRaw(text)
  if (!is.null(body)) {
    if (is.character(body)) body <- charToRaw(enc2utf8(paste(body, collapse = "\n")))
    out <- c(out, as.raw(c(10L, 10L)), body)
  }
  out
}

shared_payload_read <- function(payload) {
  if (!length(payload)) return(list(fields = list(), body = raw()))
  head <- payload[seq_len(min(length(payload), 65536L))]
  breaks <- which(head[-length(head)] == as.raw(10L) & head[-1L] == as.raw(10L))
  if (length(breaks)) {
    text <- payload[seq_len(breaks[[1L]] - 1L)]
    body <- payload[-seq_len(breaks[[1L]] + 1L)]
  } else {
    text <- payload
    body <- raw()
  }
  lines <- strsplit(rawToChar(text), "\n", fixed = TRUE)[[1L]]
  fields <- list()
  for (line in lines) {
    tab <- regexpr("\t", line, fixed = TRUE)
    if (tab < 1L) next
    value <- substring(line, tab + 1L)
    Encoding(value) <- "UTF-8"
    fields[[substring(line, 1L, tab - 1L)]] <- value
  }
  list(fields = fields, body = body)
}

# Manifest lines: "d<TAB>relative/dir" and "f<TAB>relative/file<TAB>bytes<TAB>sha256",
# relative to an object directory.
shared_manifest_text <- function(manifest) {
  check <- function(x) {
    if (any(grepl("[\t\n\r]", x))) {
      stop("File names sent to a store cannot contain tabs or line breaks.", call. = FALSE)
    }
    x
  }
  c(if (length(manifest$directories)) paste0("d\t", check(manifest$directories)),
    if (length(manifest$files)) paste0("f\t", check(manifest$files), "\t",
                                       sprintf("%.0f", manifest$sizes),
                                       "\t", manifest$hashes))
}

shared_relative_ok <- function(path) {
  nzchar(path) && !grepl("\\", path, fixed = TRUE) && !grepl("^[A-Za-z]:", path) &&
    !startsWith(path, "/") &&
    !any(strsplit(path, "/", fixed = TRUE)[[1L]] %in% c("", ".", ".."))
}

# Returns NULL unless the manifest describes a well-formed tarshare object:
# result.rds and complete at the top, everything else under files/.
shared_manifest_read <- function(body) {
  text <- if (is.raw(body)) rawToChar(body) else paste(body, collapse = "\n")
  Encoding(text) <- "UTF-8"
  lines <- strsplit(text, "\n", fixed = TRUE)[[1L]]
  parts <- strsplit(lines[nzchar(lines)], "\t", fixed = TRUE)
  kinds <- vapply(parts, `[`, character(1), 1L)
  dirs <- vapply(parts[kinds == "d"], function(x) if (length(x) == 2L) x[[2L]] else NA_character_,
                 character(1))
  files <- parts[kinds == "f"]
  if (!all(kinds %in% c("d", "f")) || anyNA(dirs) ||
      !all(vapply(files, length, integer(1)) == 4L)) return(NULL)
  paths <- vapply(files, `[`, character(1), 2L)
  sizes <- suppressWarnings(as.numeric(vapply(files, `[`, character(1), 3L)))
  hashes <- vapply(files, `[`, character(1), 4L)
  under_files <- function(x) x == "files" | startsWith(x, "files/")
  if (!all(vapply(c(dirs, paths), shared_relative_ok, logical(1))) ||
      anyDuplicated(c(dirs, paths)) || anyNA(sizes) || any(sizes < 0) ||
      any(sizes != floor(sizes)) || !all(vapply(hashes, shared_is_key, logical(1))) ||
      !all(c("complete", "result.rds") %in% paths) || !"files" %in% dirs ||
      !all(under_files(dirs)) ||
      !all(under_files(paths[!paths %in% c("complete", "result.rds")]))) {
    return(NULL)
  }
  list(directories = dirs, files = paths, sizes = sizes, hashes = hashes)
}

# Describe an object directory: everything but a server-side manifest file.
shared_manifest_scan <- function(entry) {
  inventory <- shared_scan_bundle(entry)
  files <- shared_relative(inventory$files, entry)
  keep <- files != "manifest.tsv"
  full <- inventory$files[keep]
  dirs <- shared_relative(inventory$directories, entry)
  list(directories = dirs[nzchar(dirs)], files = files[keep],
       sizes = unname(file.info(full)$size),
       hashes = vapply(full, shared_file_hash, character(1), USE.NAMES = FALSE))
}
