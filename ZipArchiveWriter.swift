import Foundation

/// A minimal, dependency-free ZIP archive writer.
///
/// Writes the ZIP "store" (method 0, uncompressed) format — no third-party
/// compression library needed, and every OS's zip reader (Finder, Windows
/// Explorer, `unzip`, Python's `zipfile`, the Files app) accepts store-method
/// entries exactly the same as deflated ones. The export this feeds is CSV
/// text, which compresses well but isn't large to begin with, so skipping
/// deflate keeps this file self-contained instead of pulling in a
/// compression dependency for a modest size trade-off.
///
/// Implements just enough of the format (PKWARE APPNOTE.TXT): local file
/// headers, straight file data, a central directory, and the end-of-central-
/// directory record. No zip64 (so no single entry or archive over 4GB — not
/// a concern for CSV exports), no encryption, no extra fields.
///
/// **This exact byte layout was cross-validated before being written here**:
/// the identical local/central-directory/end-of-central-directory structure
/// was built in Python and round-tripped through two independent readers —
/// the standard-library `zipfile` module (`testzip()` passing means every
/// CRC-32 matched) and the standalone `unzip` CLI, including nested
/// folder-style entry names (e.g. `sensor_logs/2026_07_20.csv`) extracting
/// into real subdirectories. There is no Swift toolchain available in the
/// environment this was written in, so that Python cross-check — not a
/// Swift compiler — is what this implementation's correctness rests on. If
/// anything, a bug here would most likely be a Swift-syntax slip in
/// transcribing this, not a format misunderstanding — worth a real device
/// test on first use.
struct ZipArchiveWriter {

    private struct Entry { let name: String; let data: Data }
    private var entries: [Entry] = []

    /// Add a raw file entry. `name` may contain `/` to place it in a
    /// subfolder within the archive (e.g. `"sensor_logs/2026_07_20.csv"`);
    /// zip readers create the intermediate folders from that automatically.
    mutating func add(name: String, data: Data) {
        entries.append(Entry(name: name, data: data))
    }

    mutating func addCSV(name: String, text: String) {
        add(name: name, data: Data(text.utf8))
    }

    /// Serializes every added entry into one .zip file's bytes.
    func finalize(date: Date = Date()) -> Data {
        var out = Data()
        var central = Data()
        let (dosTime, dosDate) = Self.dosDateTime(date)

        struct Recorded { let offset: UInt32; let crc: UInt32; let size: UInt32; let nameData: Data }
        var recorded: [Recorded] = []

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            var local = Data()
            local.appendLE(UInt32(0x04034b50))  // local file header signature
            local.appendLE(UInt16(20))          // version needed to extract
            local.appendLE(UInt16(0))           // general purpose bit flag
            local.appendLE(UInt16(0))           // compression method: store
            local.appendLE(dosTime)
            local.appendLE(dosDate)
            local.appendLE(crc)
            local.appendLE(size)                // compressed size (== uncompressed, store method)
            local.appendLE(size)                // uncompressed size
            local.appendLE(UInt16(nameData.count))
            local.appendLE(UInt16(0))           // extra field length
            local.append(nameData)
            local.append(entry.data)

            out.append(local)
            recorded.append(Recorded(offset: offset, crc: crc, size: size, nameData: nameData))
        }

        for r in recorded {
            var c = Data()
            c.appendLE(UInt32(0x02014b50))      // central directory file header signature
            c.appendLE(UInt16(20))               // version made by
            c.appendLE(UInt16(20))               // version needed to extract
            c.appendLE(UInt16(0))                // general purpose bit flag
            c.appendLE(UInt16(0))                // compression method: store
            c.appendLE(dosTime)
            c.appendLE(dosDate)
            c.appendLE(r.crc)
            c.appendLE(r.size)
            c.appendLE(r.size)
            c.appendLE(UInt16(r.nameData.count))
            c.appendLE(UInt16(0))                // extra field length
            c.appendLE(UInt16(0))                // file comment length
            c.appendLE(UInt16(0))                // disk number start
            c.appendLE(UInt16(0))                // internal file attributes
            c.appendLE(UInt32(0o100644 << 16))   // external file attributes: regular file, rw-r--r--
            c.appendLE(r.offset)
            c.append(r.nameData)
            central.append(c)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)

        var end = Data()
        end.appendLE(UInt32(0x06054b50))         // end of central directory signature
        end.appendLE(UInt16(0))                   // number of this disk
        end.appendLE(UInt16(0))                   // disk where central directory starts
        end.appendLE(UInt16(recorded.count))      // central directory records on this disk
        end.appendLE(UInt16(recorded.count))      // total central directory records
        end.appendLE(UInt32(central.count))       // size of central directory (bytes)
        end.appendLE(centralOffset)               // offset of start of central directory
        end.appendLE(UInt16(0))                   // comment length
        out.append(end)

        return out
    }

    /// DOS date/time fields the ZIP format expects (seconds truncated to
    /// 2-second resolution, dates relative to 1980 — a format quirk, not a
    /// bug in this code).
    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(0, (c.year ?? 1980) - 1980)
        let time = ((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2)
        let dateField = (year << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1)
        return (UInt16(time & 0xFFFF), UInt16(dateField & 0xFFFF))
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xff)); append(UInt8((v >> 8) & 0xff))
    }
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xff)); append(UInt8((v >> 8) & 0xff))
        append(UInt8((v >> 16) & 0xff)); append(UInt8((v >> 24) & 0xff))
    }
}

/// Standard CRC-32 (ISO-3309 / PKZIP polynomial 0xEDB88320), table-based.
/// Verified against `zlib.crc32` on multiple test vectors (empty data, ASCII
/// text, all 256 byte values, 10KB of repeated data) during the Python
/// cross-check described on `ZipArchiveWriter`.
enum CRC32 {
    private static let table: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
