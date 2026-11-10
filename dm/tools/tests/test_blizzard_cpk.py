"""Blizzard CPK framing: indexed ranges, ciphertext feedback and corruption."""
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'gfx/tools'))
from blizzard_cpk import Archive, name_hash


def packed(fields):
    text = ''.join(f'{value:0{width}b}' for value, width in fields)
    text += '0' * (-len(text) % 8)
    return int(text, 2).to_bytes(len(text) // 8, 'big')


def fixture(version=7, endian='<', layout=10, wrong_size=False, omit_trailer=False, revision=0x872dcda7a97a7ee1):
    first_data = b'first shader asset and its tail'
    second_data = b'second shader asset'
    full = first_data + second_data
    block = 128 if version == 7 else 0x4000
    read_block = 512 if version == 7 else 0x10000
    first = 2048 if version == 7 else 0x10000
    start = first if layout == 10 else first // read_block
    header = struct.pack(endian + 'IIQ10I', 0xa1b2c3d4, version, len(full), layout, 2, 2, start, 8, 1, 1, 8, 8, 1)
    header += bytes(8)  # sector CRC and the v6 reserved word
    if version == 7:
        header = header[:-4] + struct.pack(endian + 'III', read_block, block, 0)
    assert len(header) == (72 if version == 7 else 64)
    names = [b'Shaders/cross.shd', b'Shaders/start.shd']
    # SFI order is different from the names table: joining by row index is wrong.
    rows = [(names[1], 0, 5, 0), (names[0], len(first_data) - 4, 10, 1)]
    sfi = packed([(value, width) for name, offset, size, ix in rows for value, width in [(name_hash(name.decode()), 64), (size, 8), (1, 1), (ix, 1)]])
    locations = packed([(0, 8), (len(first_data) - 4, 8)])
    cs2do = packed([(0, 8), (len(first_data), 8)])
    ds2cs = packed([(0, 1)])
    offsets = struct.pack(endian + 'II', 0, len(names[0]) + 1)
    metadata = header + sfi + locations + cs2do + ds2cs + offsets + b'\0'.join(names) + b'\0'
    sectors = []
    for i, raw in enumerate((first_data, second_data)):
        compressed = zlib.compress(raw)
        if omit_trailer:
            compressed = compressed[:-4]
        if i:
            state = revision
            encrypted = bytearray()
            for byte in compressed:
                cipher = byte ^ (state & 255)
                encrypted.append(cipher)
                state = cipher << 56 | state >> 8
            compressed = bytes(encrypted)
        expected = len(raw) + (1 if wrong_size and i else 0)
        packet = struct.pack(endian + 'HHH', expected, 0, len(compressed) | (0x8000 if i else 0)) + compressed
        sectors.append(packet + bytes(block - len(packet)))
    return metadata + bytes(first - len(metadata)) + b''.join(sectors), full, len(first_data) - 4


class BlizzardCpkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'test.cpk'

    def check_archive(self, **kwargs):
        data, full, offset = fixture(**kwargs)
        self.path.write_bytes(data)
        with Archive(self.path) as archive:
            entries = {e.name: e for e in archive.entries}
            self.assertEqual(archive.read(entries['Shaders/start.shd']), b'first')
            self.assertEqual(archive.read(entries['Shaders/cross.shd']), full[offset:offset + 10])

    def test_switch_patch_and_legacy_keep_first_packet(self):
        for layout in (2, 10):
            with self.subTest(layout=layout):
                self.check_archive(layout=layout)

    def test_big_endian_v6_has_same_msb_first_index(self):
        self.check_archive(version=6, endian='>', layout=2)

    def test_length_delimited_packet_without_zlib_trailer(self):
        self.check_archive(omit_trailer=True)

    def test_new_encoding_revision_is_selected_from_zlib_header(self):
        self.check_archive(revision=0x873ae8e53c11d761)

    def test_wrong_output_length_is_not_zero_filled(self):
        data, _, _ = fixture(wrong_size=True)
        self.path.write_bytes(data)
        with Archive(self.path) as archive:
            entry = next(e for e in archive.entries if e.name.endswith('cross.shd'))
            with self.assertRaisesRegex(ValueError, 'chunk length'):
                archive.read(entry)

    def test_index_dimensions_are_bounded(self):
        data, _, _ = fixture()
        broken = bytearray(data)
        struct.pack_into('<I', broken, 20, 2_000_001)
        self.path.write_bytes(broken)
        with self.assertRaisesRegex(ValueError, 'index dimensions'):
            Archive(self.path)

    def test_truncated_metadata_and_payload_are_rejected(self):
        data, _, _ = fixture()
        for length in (0, 63, 72, 2049):
            with self.subTest(length=length):
                self.path.write_bytes(data[:length])
                with self.assertRaises(ValueError), Archive(self.path) as archive:
                    archive.read(archive.entries[0])

    def test_scanner_dispatches_by_magic_and_reads_shader_entries_only(self):
        import os
        with mock.patch.dict(os.environ, DM_GAME='01001B300B9BE000'):
            import shader_split as split
        data, _, _ = fixture()
        self.path.write_bytes(data)
        with mock.patch.object(split, 'glslc_shaders', return_value=[]) as scan:
            self.assertEqual(split.scan_file_in((str(self.path), 'test.cpk')), ('test.cpk', {}, set(), {}))
            self.assertEqual(scan.call_count, 2)
            self.assertEqual(scan.call_args_list[1].args[0], b'first')
        # Large non-shader members must never be read, even when a shader entry
        # carries a variant suffix after its extension.
        from blizzard_cpk import Entry
        shader = Entry('Shaders/test.SHD|variant', 0, 3, 1)
        audio = Entry('Audio/unused.fsb', 3, 1 << 32, 1)
        archive = mock.MagicMock()
        archive.__enter__.return_value = archive
        archive.entries = [audio, shader]; archive.read.return_value = b'shd'
        with mock.patch('blizzard_cpk.Archive', return_value=archive), mock.patch.object(split, 'glslc_shaders', return_value=[]) as scan:
            split.blizzard_cpk_shaders(self.path, 'test.cpk', [])
            archive.read.assert_called_once_with(shader)
            scan.assert_called_once_with(b'shd', '/test.cpk/Shaders/test.SHD|variant', need=False)


if __name__ == '__main__':
    unittest.main()
