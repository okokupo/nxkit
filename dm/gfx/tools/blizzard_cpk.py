"""Bounded reader for Blizzard CPK v6/v7 archives (not CRI's CPK format).

The index addresses a decompressed stream through bit-packed file locations and
compressed-sector offsets. Read only the sectors needed by an entry; shader
discovery must not expand multi-gigabyte audio and texture archives in memory.
Format reference: https://github.com/RedMadKnight/D3CPKUnpack (CPK specification).
"""
import bisect
import collections
from dataclasses import dataclass
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
from romfs import open

MAGICS = (b'\xd4\xc3\xb2\xa1', b'\xa1\xb2\xc3\xd4')
# Console revisions keep the packet format but change the feedback initializer.
# The newer value is also present in the v7 game's packet decoder (MOV/MOVK,
# XOR, then EXTR by eight bits). Zlib's CMF/FLG header distinguishes the two.
CIPHER_SEEDS = tuple(value.to_bytes(8, 'little') for value in (0x872dcda7a97a7ee1, 0x873ae8e53c11d761))


def bits(data, offset, width):
    if not width:
        return 0
    start, end = offset // 8, (offset + width + 7) // 8
    if end > len(data):
        raise ValueError('truncated CPK bit table')
    return (int.from_bytes(data[start:end], 'big') >> (end * 8 - offset - width)) & ((1 << width) - 1)


def name_hash(name):
    value = 0xcbf29ce484222325
    for byte in name.lower().encode('latin1'):
        value = ((value ^ byte) * 0x100000001b3) & 0xffffffffffffffff
    return value


@dataclass(frozen=True)
class Entry:
    name: str
    offset: int
    size: int
    locations: int


class Archive:
    def __init__(self, path):
        self.file = open(path, 'rb')
        self.cache = collections.OrderedDict()
        try:
            self._index()
        except BaseException:
            self.file.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.file.close()

    def _at(self, offset, size):
        if offset < 0 or size < 0 or offset + size > self.size:
            raise ValueError('CPK range outside archive')
        self.file.seek(offset)
        data = self.file.read(size)
        if len(data) != size:
            raise ValueError('truncated CPK range')
        return data

    def _index(self):
        self.file.seek(0, 2)
        self.size = self.file.tell()
        h = self._at(0, min(72, self.size))
        if len(h) < 64 or h[:4] not in MAGICS:
            raise ValueError('not a Blizzard CPK archive')
        self.endian = '<' if h[:4] == MAGICS[0] else '>'
        version, self.unpacked, self.layout, count, nloc, first, fs, runs, index, loc, cs, ds = struct.unpack_from(self.endian + 'IQ10I', h, 4)
        if version == 6:
            read_sector, self.block, header = 0x10000, 0x4000, 64
        elif version == 7 and len(h) >= 72:
            read_sector, self.block = struct.unpack_from(self.endian + 'II', h, 60)
            header = 72
        else:
            raise ValueError(f'unsupported Blizzard CPK version {version}')
        if self.layout not in (2, 10) or not 0 < read_sector <= 0x100000 or not 0 < self.block <= 0x100000:
            raise ValueError('unsupported CPK sector layout')
        if count > 2_000_000 or nloc > 2_000_000 or any(w > 64 for w in (fs, runs, index, loc, cs, ds)):
            raise ValueError('invalid CPK index dimensions')
        self.first = first if self.layout == 10 else first * read_sector
        if not header <= self.first <= self.size:
            raise ValueError('CPK payload offset outside archive')
        self.sectors = (self.size - self.first + self.block - 1) // self.block
        ndecomp = (self.unpacked + self.block - 1) // self.block
        pos = header

        def table(n, width):
            nonlocal pos
            size = (n * width + 7) // 8
            data = self._at(pos, size)
            pos += size
            return data

        row_width = 64 + fs + runs + index
        rows = table(count, row_width)
        locations = table(nloc, loc)
        compressed = table(self.sectors, cs)
        table(ndecomp, ds or self.sectors.bit_length())
        offsets = self._at(pos, count * 4)
        pos += count * 4
        # Legacy metadata can spill into sector zero's skip preamble.
        names_end = min(self.size, self.first + self.block)
        names = self._at(pos, names_end - pos)
        by_hash = {}
        for i in range(count):
            at = i * row_width
            key = bits(rows, at, 64)
            size = bits(rows, at + 64, fs)
            nruns = bits(rows, at + 64 + fs, runs)
            ix = bits(rows, at + 64 + fs + runs, index)
            if nruns and (nruns != 1 or ix >= nloc):
                raise ValueError('unsupported CPK fragmented entry')
            start = bits(locations, ix * loc, loc) if nruns else 0
            if nruns and start + size > self.unpacked:
                raise ValueError('CPK entry outside decompressed stream')
            by_hash[key] = (start, size, nruns)
        self.entries = []
        for i in range(count):
            no = struct.unpack_from(self.endian + 'I', offsets, i * 4)[0]
            end = names.find(b'\0', no, no + 4097)
            if no >= len(names) or end < 0:
                raise ValueError('invalid CPK entry name')
            name = names[no:end].decode('latin1')
            row = by_hash.get(name_hash(name))
            if row is None:
                raise ValueError('CPK name has no file index record')
            self.entries.append(Entry(name, *row))
        self.offsets = [bits(compressed, i * cs, cs) for i in range(self.sectors)]
        if any(a > b for a, b in zip(self.offsets, self.offsets[1:])):
            raise ValueError('unordered CPK sector offsets')

    def _sector(self, index):
        if index in self.cache:
            self.cache.move_to_end(index)
            return self.cache[index]
        offset = self.first + index * self.block
        data = self._at(offset, min(self.block, self.size - offset))
        pos = 0
        # The first packet is payload on Switch v7, including legacy layout 2.
        # ClientCommon's first 41,548 bytes are one complete shader asset; treating
        # its compressed length as a metadata skip loses that asset and shifts
        # every later byte in the first sector away from its indexed location.
        out = bytearray()
        while pos + 6 <= len(data):
            lo, hi, stored = struct.unpack_from(self.endian + '3H', data, pos)
            if not stored:
                break
            length, expected = stored & 0x7fff, lo | hi << 16
            pos += 6
            if not length or pos + length > len(data) or expected > 16 * 1024 * 1024:
                raise ValueError('invalid CPK compressed chunk')
            chunk = data[pos:pos + length]
            pos += length
            if stored & 0x8000:
                # Ciphertext feedback is eight bytes long; each chunk resets it.
                seeds = [seed for seed in CIPHER_SEEDS if length >= 2 and
                         (cmf := chunk[0] ^ seed[0]) & 15 == 8 and cmf >> 4 <= 7 and
                         ((cmf << 8) | (chunk[1] ^ seed[1])) % 31 == 0]
                if len(seeds) != 1:
                    raise ValueError('unsupported CPK packet encoding revision')
                seed, = seeds
                chunk = bytes(b ^ (seed[i] if i < 8 else chunk[i - 8]) for i, b in enumerate(chunk))
            # Packets are length-delimited by CPK; some omit the zlib trailer.
            # Require the exact declared output instead of accepting short data.
            decoder = zlib.decompressobj()
            decoded = decoder.decompress(chunk, expected + 1)
            if decoder.unconsumed_tail:
                raise ValueError('CPK chunk exceeds declared decompressed size')
            if len(decoded) != expected:
                raise ValueError(f'CPK chunk length {len(decoded)} != {expected}')
            out.extend(decoded)
        result = bytes(out)
        self.cache[index] = result
        if len(self.cache) > 64:
            self.cache.popitem(last=False)
        return result

    def read(self, entry):
        if not entry.locations or not entry.size:
            return b''
        index = max(0, bisect.bisect_right(self.offsets, entry.offset) - 1)
        cursor, end = entry.offset, entry.offset + entry.size
        out = bytearray()
        while cursor < end and index < self.sectors:
            start = self.offsets[index]
            data = self._sector(index)
            if start > cursor:
                raise ValueError('gap in CPK entry data')
            take = min(end, start + len(data)) - cursor
            if take > 0:
                out.extend(data[cursor - start:cursor - start + take])
                cursor += take
            index += 1
        if cursor != end:
            raise ValueError('incomplete CPK entry data')
        return bytes(out)
