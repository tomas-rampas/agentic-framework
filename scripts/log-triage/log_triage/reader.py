"""Streaming input reader: bounded memory, gzip streams, encodings, oversized lines.

Guarantees:
  * never holds more than ``read_chunk_bytes + max_line_bytes`` of input in memory;
  * yields lines as ``(line_no, byte_offset, text, truncated)`` tuples;
  * counts every decoding replacement, truncated line and decompression event;
  * detects binary and compressed inputs by magic bytes, never by extension alone;
  * salvages everything decompressed before a truncated/corrupt gzip stream ends.
"""
from __future__ import annotations

import codecs
import os
import zlib
from typing import Iterator, List, Optional, Tuple

GZIP_MAGIC = b"\x1f\x8b"

_COMPRESSION_MAGIC = (
    (b"BZh", "bzip2"),
    (b"\xfd7zXZ\x00", "xz"),
    (b"\x28\xb5\x2f\xfd", "zstd"),
    (b"PK\x03\x04", "zip"),
    (b"\x37\x7a\xbc\xaf\x27\x1c", "7z"),
    (b"Rar!\x1a\x07", "rar"),
    (b"\x04\x22\x4d\x18", "lz4"),
)

_BINARY_MAGIC = (
    (b"ElfFile\x00", "evtx", "Windows Event Log binary (EVTX). Export it as XML first: "
                             "`wevtutil qe <log> /f:xml > events.xml` or Event Viewer > Save As > XML."),
    (b"LPKSHHRH", "journal", "systemd journal binary file. Export it as JSON first: "
                             "`journalctl --file=<file> -o json > journal.json`."),
    (b"\x7fELF", "elf", "ELF executable/object file, not a log."),
    (b"MZ", "pe", "Windows executable (PE), not a log."),
    (b"%PDF", "pdf", "PDF document, not a log."),
    (b"\x89PNG", "png", "PNG image, not a log."),
    (b"\xd4\xc3\xb2\xa1", "pcap", "PCAP capture, not a log."),
    (b"\xa1\xb2\xc3\xd4", "pcap", "PCAP capture, not a log."),
    (b"\x0a\x0d\x0d\x0a", "pcapng", "PCAPNG capture, not a log."),
    (b"SQLite format 3\x00", "sqlite", "SQLite database, not a text log."),
)

ETL_DIAGNOSTIC = ("Windows Event Trace Log (ETL) binary. Convert it first: "
                  "`tracerpt <file>.etl -o events.xml -of XML` or `netsh trace convert`.")


class InputStatus:
    COMPLETE = "complete"
    TRUNCATED = "truncated"        # compressed stream ended early
    LIMIT = "limit"                # decompression limit reached
    CORRUPT = "corrupt"
    FAILED = "failed"


class UnsupportedCompression(Exception):
    def __init__(self, kind: str):
        super().__init__(kind)
        self.kind = kind

    def hint(self) -> str:
        return ("%s-compressed input is not supported; only gzip streams are decompressed. "
                "Decompress it first (e.g. `%s`) and re-run." % (self.kind, {
                    "bzip2": "bzip2 -dk <file>", "xz": "xz -dk <file>", "zstd": "zstd -d <file>",
                    "zip": "unzip <file>", "7z": "7z x <file>", "rar": "unrar x <file>", "lz4": "lz4 -d <file>",
                }.get(self.kind, "<decompress>")))


def detect_compression(head: bytes) -> Optional[str]:
    if head.startswith(GZIP_MAGIC):
        return "gzip"
    for magic, name in _COMPRESSION_MAGIC:
        if head.startswith(magic):
            return name
    return None


def _looks_utf16(head: bytes) -> bool:
    if head.startswith(b"\xff\xfe") or head.startswith(b"\xfe\xff"):
        return True
    if len(head) < 16:
        return False
    window = head[:4096]
    n = len(window) // 2
    if n == 0:
        return False
    even_nul = sum(1 for i in range(0, n * 2, 2) if window[i] == 0)
    odd_nul = sum(1 for i in range(1, n * 2, 2) if window[i] == 0)
    return (odd_nul > n * 0.4 and even_nul < n * 0.05) or (even_nul > n * 0.4 and odd_nul < n * 0.05)


def detect_binary(head: bytes, path: str) -> Tuple[Optional[str], Optional[str]]:
    for magic, kind, hint in _BINARY_MAGIC:
        if head.startswith(magic):
            return kind, hint
    if not head:
        return None, None
    nul_ratio = head.count(b"\x00") / float(len(head))
    if path.lower().endswith(".etl") and nul_ratio > 0.2:
        return "etl", ETL_DIAGNOSTIC
    if _looks_utf16(head):
        return None, None          # UTF-16 text: NUL bytes are expected
    if nul_ratio > 0.05:
        return "binary", "Input contains NUL bytes and is not UTF-16 text; unsupported binary content."
    window = head[:4096]
    ctrl = sum(1 for b in window if 0 < b < 9 or (13 < b < 32 and b != 27))
    if ctrl > len(window) * 0.1:
        return "binary", "Input is dominated by control bytes; unsupported binary content."
    # Random-looking binary (compressed or encrypted payloads without a known magic
    # number) carries ~10% control bytes *and* high bytes that never form valid
    # UTF-8.  Legacy single-byte text encodings (Latin-1, Windows-125x, KOI8) also
    # fail UTF-8 validation but contain almost no control bytes, so both signals
    # are required before an input is refused as binary.
    if ctrl > len(window) * 0.03:
        invalid = window.decode("utf-8", errors="replace").count("\ufffd")
        if invalid > len(window) * 0.2:
            return "binary", "Input mixes control bytes with byte sequences that are not valid text in any supported encoding; unsupported binary content."
    return None, None


def detect_encoding(head: bytes) -> Tuple[str, int]:
    """Return (codec, bom_length)."""
    if head.startswith(b"\xef\xbb\xbf"):
        return "utf-8", 3
    if head.startswith(b"\xff\xfe"):
        return "utf-16-le", 2
    if head.startswith(b"\xfe\xff"):
        return "utf-16-be", 2
    if _looks_utf16(head):
        window = head[:4096]
        n = len(window) // 2
        odd_nul = sum(1 for i in range(1, n * 2, 2) if window[i] == 0)
        even_nul = sum(1 for i in range(0, n * 2, 2) if window[i] == 0)
        return ("utf-16-le", 0) if odd_nul >= even_nul else ("utf-16-be", 0)
    return "utf-8", 0


class _RawStream:
    """Uncompressed file stream with a consumed-bytes counter."""

    def __init__(self, fh):
        self._fh = fh
        self.consumed = 0
        self.truncated = False
        self.error: Optional[str] = None

    def read(self, n: int) -> bytes:
        data = self._fh.read(n)
        self.consumed += len(data)
        return data

    def close(self) -> None:
        self._fh.close()


class GzipStream:
    """Incremental gzip (multi-member) decompressor that salvages partial data.

    ``read(n)`` returns up to ``n`` decompressed bytes. After EOF, ``truncated`` is
    True when the compressed input ended before the stream's end marker and
    ``error`` is set when the compressed data was corrupt. Data decompressed before
    the failure point is always delivered.
    """

    def __init__(self, fh, chunk: int = 65536):
        self._fh = fh
        self._chunk = chunk
        self._d = zlib.decompressobj(31)
        self._pending = b""     # compressed bytes not yet fed (unconsumed_tail / unused_data)
        self._buf = b""
        self._eof = False
        self.consumed = 0
        self.truncated = False
        self.error: Optional[str] = None
        self._fed_any = False

    def read(self, n: int) -> bytes:
        while len(self._buf) < n and not self._eof:
            self._fill(n - len(self._buf))
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def _fill(self, want: int) -> None:
        comp = self._pending
        self._pending = b""
        if not comp:
            comp = self._fh.read(self._chunk)
            self.consumed += len(comp)
            if not comp:
                self._eof = True
                if self._d is not None and self._fed_any and not self._d.eof:
                    self.truncated = True
                return
        if self._d is None:
            # previous member finished cleanly; more bytes follow -> new member (or trailing junk)
            if not comp.startswith(GZIP_MAGIC):
                if comp.strip(b"\x00"):
                    self.error = "trailing data after gzip stream is not a gzip member"
                self._eof = True
                return
            self._d = zlib.decompressobj(31)
        try:
            data = self._d.decompress(comp, max(want, 65536))
        except zlib.error as exc:
            self.error = "corrupt gzip data: %s" % exc
            self._eof = True
            self._d = None
            return
        self._fed_any = True
        self._buf += data
        if self._d.unconsumed_tail:
            self._pending = self._d.unconsumed_tail
        elif self._d.eof:
            self._pending = self._d.unused_data
            self._d = None
            if not self._pending:
                # peek for another member
                nxt = self._fh.read(self._chunk)
                self.consumed += len(nxt)
                if nxt:
                    self._pending = nxt
                else:
                    self._eof = True

    def close(self) -> None:
        self._fh.close()


def open_stream(path: str):
    """Open ``path`` as a decompressed byte stream (raw or gzip). Raises UnsupportedCompression."""
    fh = open(path, "rb")
    head = fh.read(8)
    fh.seek(0)
    kind = detect_compression(head)
    if kind == "gzip":
        return GzipStream(fh), "gzip"
    if kind is not None:
        fh.close()
        raise UnsupportedCompression(kind)
    return _RawStream(fh), None


class LineReader:
    """Iterate a (possibly gzip-compressed) text input line by line with bounded memory."""

    def __init__(self, path: str, limits, encoding: Optional[str] = None):
        self.path = path
        self.limits = limits
        self.encoding_override = encoding
        self.encoding = "utf-8"
        self.bom = 0
        self.compression: Optional[str] = None
        self.status = InputStatus.COMPLETE
        self.error: Optional[str] = None
        self.bytes_compressed = 0
        self.bytes_read = 0
        self.lines = 0
        self.truncated_lines = 0
        self.discarded_bytes = 0
        self.replacements = 0
        self.unterminated_last_line = False

    def _emit(self, data: bytes, offset: int, truncated: bool) -> Tuple[int, int, str, bool]:
        max_line = self.limits.max_line_bytes
        if len(data) > max_line:
            self.discarded_bytes += len(data) - max_line
            data = data[:max_line]
            truncated = True
        if data.endswith(b"\r"):
            data = data[:-1]
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            text = data.decode("utf-8", "replace")
            self.replacements += text.count("�")
        self.lines += 1
        if truncated:
            self.truncated_lines += 1
        return self.lines, offset, text, truncated

    def __iter__(self) -> Iterator[Tuple[int, int, str, bool]]:
        limits = self.limits
        max_line = limits.max_line_bytes
        chunk_size = limits.read_chunk_bytes
        stream, self.compression = open_stream(self.path)
        try:
            first = True
            utf16 = False
            decoder = None
            carry = b""
            carry_offset = 0
            discarding = False
            offset = 0
            text_carry = ""
            text_carry_units = 0     # code units consumed before text_carry (UTF-16 path)
            while True:
                chunk = stream.read(chunk_size)
                if first:
                    first = False
                    enc, bom = detect_encoding(chunk[:4096])
                    if self.encoding_override:
                        enc, bom = self.encoding_override, 0
                    self.encoding, self.bom = enc, bom
                    utf16 = enc.startswith("utf-16")
                    if bom:
                        chunk = chunk[bom:]
                        offset = bom
                        carry_offset = bom
                    if utf16:
                        decoder = codecs.getincrementaldecoder(enc)(errors="replace")
                if chunk:
                    self.bytes_read += len(chunk)
                    self.bytes_compressed = stream.consumed
                    if self.compression == "gzip":
                        if self.bytes_read > limits.max_decompressed_bytes:
                            self.status = InputStatus.LIMIT
                            self.error = ("decompressed size exceeded max_decompressed_bytes (%d)"
                                          % limits.max_decompressed_bytes)
                            chunk = b""
                        elif (self.bytes_read > 1_048_576 and self.bytes_compressed > 0 and
                              self.bytes_read // self.bytes_compressed > limits.max_compression_ratio):
                            self.status = InputStatus.LIMIT
                            self.error = ("compression ratio exceeded max_compression_ratio (%d)"
                                          % limits.max_compression_ratio)
                            chunk = b""
                if not chunk:
                    if getattr(stream, "truncated", False) and self.status == InputStatus.COMPLETE:
                        self.status = InputStatus.TRUNCATED
                        self.error = "compressed stream ended before the end-of-stream marker"
                    if getattr(stream, "error", None) and self.status == InputStatus.COMPLETE:
                        self.status = InputStatus.CORRUPT
                        self.error = stream.error
                    if utf16:
                        text_carry += decoder.decode(b"", final=True)
                        if text_carry:
                            self.unterminated_last_line = True
                            yield self._emit_text(text_carry, self.bom + text_carry_units * 2)
                    elif carry or discarding:
                        self.unterminated_last_line = True
                        yield self._emit(carry, carry_offset, discarding)
                    break
                if utf16:
                    text = text_carry + decoder.decode(chunk)
                    parts = text.split("\n")
                    for part in parts[:-1]:
                        yield self._emit_text(part, self.bom + text_carry_units * 2)
                        text_carry_units += len(part) + 1
                    text_carry = parts[-1]
                    if len(text_carry) > max_line:
                        self.discarded_bytes += (len(text_carry) - max_line) * 2
                        text_carry = text_carry[:max_line]
                    continue
                parts = chunk.split(b"\n")
                if len(parts) == 1:
                    if discarding:
                        self.discarded_bytes += len(chunk)
                    else:
                        carry += chunk
                        if len(carry) > max_line:
                            self.discarded_bytes += len(carry) - max_line
                            carry = carry[:max_line]
                            discarding = True
                    offset += len(chunk)
                    continue
                head_len = len(parts[0])
                if discarding:
                    self.discarded_bytes += head_len
                    yield self._emit(carry, carry_offset, True)
                else:
                    yield self._emit(carry + parts[0], carry_offset, False)
                discarding = False
                pos = offset + head_len + 1
                for part in parts[1:-1]:
                    yield self._emit(part, pos, False)
                    pos += len(part) + 1
                carry = parts[-1]
                carry_offset = pos
                if len(carry) > max_line:
                    self.discarded_bytes += len(carry) - max_line
                    carry = carry[:max_line]
                    discarding = True
                offset += len(chunk)
        finally:
            stream.close()

    def _emit_text(self, text: str, offset: int) -> Tuple[int, int, str, bool]:
        truncated = False
        if text.endswith("\r"):
            text = text[:-1]
        if len(text) > self.limits.max_line_bytes:
            text = text[: self.limits.max_line_bytes]
            truncated = True
            self.truncated_lines += 1
        self.replacements += text.count("�")
        self.lines += 1
        return self.lines, offset, text, truncated


class Sample:
    """Bounded head sample used for detection."""

    __slots__ = ("raw", "text", "lines", "encoding", "compression", "binary_kind", "binary_hint",
                 "bom", "total_size", "complete", "shape_cache")

    def __init__(self) -> None:
        self.raw: bytes = b""
        self.text: str = ""
        self.lines: List[str] = []
        self.encoding: str = "utf-8"
        self.compression: Optional[str] = None
        self.binary_kind: Optional[str] = None
        self.binary_hint: Optional[str] = None
        self.bom: int = 0
        self.total_size: int = 0
        self.complete: bool = False   # True when the sample covers the entire (decompressed) input
        self.shape_cache = None       # per-sample memo used by the structured-format sniffers


def read_sample(path: str, limits) -> Sample:
    """Read a bounded head sample (decompressed) for format detection."""
    sample = Sample()
    try:
        sample.total_size = os.path.getsize(path)
    except OSError:
        sample.total_size = 0
    try:
        stream, sample.compression = open_stream(path)
    except UnsupportedCompression as exc:
        sample.compression = exc.kind
        return sample
    try:
        data = stream.read(limits.detect_sample_bytes)
        probe = stream.read(1) if len(data) >= limits.detect_sample_bytes else b""
        sample.complete = not probe and len(data) < limits.detect_sample_bytes or (not probe and not data)
        if len(data) >= limits.detect_sample_bytes and not probe:
            sample.complete = True
    finally:
        stream.close()
    sample.raw = data
    kind, hint = detect_binary(data[:8192], path)
    if kind:
        sample.binary_kind, sample.binary_hint = kind, hint
        return sample
    enc, bom = detect_encoding(data[:4096])
    sample.encoding, sample.bom = enc, bom
    body = data[bom:]
    text = body.decode(enc, "replace")
    sample.text = text
    lines = text.split("\n")
    if len(lines) > 1 and (not sample.complete or lines[-1] == ""):
        lines = lines[:-1]
    sample.lines = [ln.rstrip("\r") for ln in lines[: limits.detect_sample_lines]]
    return sample
