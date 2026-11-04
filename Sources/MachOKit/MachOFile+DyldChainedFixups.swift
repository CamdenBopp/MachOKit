//
//  MachOFile+DyldChainedFixups.swift
//
//
//  Created by p-x9 on 2024/01/11.
//
//

import Foundation
#if compiler(>=6.0) || (compiler(>=5.10) && hasFeature(AccessLevelOnImport))
internal import FileIO
internal import FileIOBinary
#else
@_implementationOnly import FileIO
@_implementationOnly import FileIOBinary
#endif
import MachOKitC

extension MachOFile {
    public struct DyldChainedFixups {
        typealias FileSlice = File.FileSlice

        let fileSlice: FileSlice
        let isSwapped: Bool
    }
}

extension MachOFile.DyldChainedFixups: DyldChainedFixupsProtocol {
    public var header: DyldChainedFixupsHeader? {
        let ret = fileSlice.ptr
            .assumingMemoryBound(to: DyldChainedFixupsHeader.self)
            .pointee
        return isSwapped ? ret.swapped : ret
    }

    public var startsInImage: DyldChainedStartsInImage? {
        guard let header else { return nil }
        let offset: Int = numericCast(header.starts_offset)
        let ptr = fileSlice.ptr
            .advanced(by: offset)
        let layout = ptr
            .assumingMemoryBound(to: DyldChainedStartsInImage.Layout.self)
            .pointee
        let ret: DyldChainedStartsInImage = .init(
            layout: layout,
            offset: offset
        )
        return isSwapped ? ret.swapped : ret
    }

    public func startsInSegments(
        of startsInImage: DyldChainedStartsInImage?
    ) -> [DyldChainedStartsInSegment] {
        guard let startsInImage else { return [] }
        let offsets: [Int] = {
            let ptr = fileSlice.ptr
                .advanced(by: startsInImage.offset)
                .advanced(by: DyldChainedStartsInImage.layoutOffset(of: \.seg_info_offset))
            return UnsafeBufferPointer(
                start: ptr.assumingMemoryBound(to: UInt32.self),
                count: numericCast(startsInImage.seg_count)
            )
            .map { isSwapped ? $0.byteSwapped : $0 }
            .map { numericCast($0) }
        }()

        let ptr = fileSlice.ptr
            .advanced(by: startsInImage.offset)
        return offsets.enumerated().map { index, offset in
            // A segment with no fixups has `seg_info_offset` 0 (dyld skips
            // it). Reading there would reinterpret the image-level header as
            // this segment's starts, with a garbage `page_count`.
            guard offset != 0 else {
                return .init(
                    layout: .init(),
                    offset: startsInImage.offset,
                    segmentIndex: index
                )
            }
            let layout = ptr.advanced(by: offset)
                .assumingMemoryBound(to: DyldChainedStartsInSegment.Layout.self)
                .pointee
            let offset: Int = startsInImage.offset + offset
            let ret: DyldChainedStartsInSegment = .init(
                layout: layout,
                offset: offset,
                segmentIndex: index
            )
            return isSwapped ? ret.swapped : ret
        }
    }

    // xcrun dyld_info -fixup_chains "Path to Binary"
    public func pages(
        of startsInSegment: DyldChainedStartsInSegment?
    ) -> [DyldChainedPage] {
        guard let startsInSegment else { return [] }

        let ptr = fileSlice.ptr
            .advanced(by: startsInSegment.offset)
            .advanced(by: startsInSegment.layoutOffset(of: \.page_start))
            .assumingMemoryBound(to: UInt16.self)
        return UnsafeBufferPointer(
            start: ptr,
            count: numericCast(
                startsInSegment.page_count
            )
        )
        .map {
            isSwapped ? $0.byteSwapped : $0
        }
        .enumerated().map { .init(offset: $1, index: $0) }
    }

    public var imports: [DyldChainedImport] {
        guard let header,
              let  importsFormat = header.importsFormat else {
            return []
        }
        let offset: Int = numericCast(header.imports_offset)
        let ptr = fileSlice.ptr
            .advanced(by: offset)
        let count: Int = numericCast(header.imports_count)

        switch importsFormat {
        case .general:
            return UnsafeBufferPointer(
                start: ptr
                    .assumingMemoryBound(to: DyldChainedImportGeneral.self),
                count: count
            )
            .map { isSwapped ? $0.swapped : $0 }
            .map { .general($0) }

        case .addend:
            return UnsafeBufferPointer(
                start: ptr
                    .assumingMemoryBound(to: DyldChainedImportAddend.self),
                count: count
            )
            .map { isSwapped ? $0.swapped : $0 }
            .map { .addend($0) }

        case .addend64:
            return UnsafeBufferPointer(
                start: ptr
                    .assumingMemoryBound(to: DyldChainedImportAddend64.self),
                count: count
            )
            .map { isSwapped ? $0.swapped : $0 }
            .map { .addend64($0) }
        }
    }

    public func symbolName(for nameOffset: Int) -> String? {
        guard let header else { return nil }
        let ptr = fileSlice.ptr
            .advanced(by: numericCast(header.symbols_offset))
            .advanced(by: nameOffset)
            .assumingMemoryBound(to: CChar.self)
        return String(cString: ptr)
    }
}

extension MachOFile.DyldChainedFixups {
    // https://github.com/apple-oss-distributions/dyld/blob/d1a0f6869ece370913a3f749617e457f3b4cd7c4/common/MachOLoaded.cpp#L884
    // xcrun dyld_info -fixup_chain_details "Path to Binary"
    // xcrun dyld_info -fixups "Path to Binary"
    public func pointers(
        of startsInSegment: DyldChainedStartsInSegment,
        in machO: MachOFile
    ) -> [DyldChainedFixupPointer] {
        let pages = pages(of: startsInSegment)
        guard pages.count > 0, startsInSegment.page_size > 0,
              let bytes = chainBytes(of: startsInSegment, pageCount: pages.count, in: machO),
              let pagesFileSlice = bytes.fileSlice else { return [] }

        var pointers: [DyldChainedFixupPointer] = []

        for (index, page) in pages.enumerated() {
            var offsetInPage = page.offset

            if page.isNone { continue }
            if page.isMulti {
                var overflowIndex = Int(offsetInPage & ~UInt16(DYLD_CHAINED_PTR_START_MULTI))
                var chainEnd = false
                while !chainEnd {
                    chainEnd = pages[overflowIndex].offset & UInt16(DYLD_CHAINED_PTR_START_LAST) != 0
                    offsetInPage = pages[overflowIndex].offset & ~UInt16(DYLD_CHAINED_PTR_START_LAST)
                    let pageContentStart: Int = index * numericCast(startsInSegment.page_size)
                    let chainOffset = pageContentStart + numericCast(offsetInPage)
                    walkChain(offset: chainOffset, pagesFileSlice: pagesFileSlice, fileOffset: bytes.fileOffset, of: startsInSegment, pointers: &pointers)
                    overflowIndex += 1
                }
            } else {
                let pageContentStart: Int = index * numericCast(startsInSegment.page_size)
                let chainOffset = pageContentStart + numericCast(offsetInPage)
                walkChain(offset: chainOffset, pagesFileSlice: pagesFileSlice, fileOffset: bytes.fileOffset, of: startsInSegment, pointers: &pointers)
            }
        }

        return pointers
    }

    private func walkChain(
        offset: Int,
        pagesFileSlice: FileSlice,
        fileOffset: Int,
        of startsInSegment: DyldChainedStartsInSegment,
        pointers: inout [DyldChainedFixupPointer]
    ) {
        guard let pointerFormat = startsInSegment.pointerFormat else {
            return
        }
        _ = DyldChainedFixupPointer.walkChain(
            startOffset: offset,
            pointerOffsetBias: fileOffset,
            pointerFormat: pointerFormat,
            pointers: &pointers
        ) { offset in
            _fixupInfo(
                at: offset,
                in: pagesFileSlice,
                pointerFormat: pointerFormat
            )
        }
    }
}

extension MachOFile.DyldChainedFixups {
    public func pointer(for offset: UInt64, in machO: MachOFile) -> DyldChainedFixupPointer? {
        guard let startsInImage = startsInImage else { return nil }
        // `offset` counts in the file, like the offsets of the pointers this
        // answers with, so a segment is matched by where its chain's bytes
        // lie there: `segment_offset` counts in memory.
        var found: (DyldChainedStartsInSegment, ChainBytes, [DyldChainedPage])?
        for candidate in startsInSegments(of: startsInImage) {
            let pages = pages(of: candidate)
            guard !pages.isEmpty, candidate.page_size > 0,
                  let bytes = chainBytes(of: candidate, pageCount: pages.count, in: machO),
                  offset >= UInt64(bytes.fileOffset),
                  offset - UInt64(bytes.fileOffset) < UInt64(bytes.length) else {
                continue
            }
            found = (candidate, bytes, pages)
            break
        }
        guard let (startsInSegment, bytes, pages) = found,
              let pagesFileSlice = bytes.fileSlice else {
            return nil
        }

        let pageSize: Int = numericCast(startsInSegment.page_size)
        let pageIndex: Int = numericCast(
            (offset - UInt64(bytes.fileOffset)) / UInt64(pageSize)
        )
        let page = pages[pageIndex]
        guard !page.isNone else { return nil }

        let pageContentStart = pageIndex * pageSize
        var offsetInPage = page.offset
        if page.isMulti {
            var overflowIndex = Int(offsetInPage & ~UInt16(DYLD_CHAINED_PTR_START_MULTI))
            var chainEnd = false
            while !chainEnd {
                chainEnd = pages[overflowIndex].offset & UInt16(DYLD_CHAINED_PTR_START_LAST) != 0
                offsetInPage = pages[overflowIndex].offset & ~UInt16(DYLD_CHAINED_PTR_START_LAST)
                let chainOffset = pageContentStart + numericCast(offsetInPage)

                if let pointer = walkChainAndFindPointer(
                    for: offset,
                    chainOffset: chainOffset,
                    pagesFileSlice: pagesFileSlice,
                    fileOffset: bytes.fileOffset,
                    of: startsInSegment
                ) {
                    return pointer
                }

                overflowIndex += 1
            }
        } else {
            let chainOffset = pageContentStart + numericCast(offsetInPage)
            return walkChainAndFindPointer(
                for: offset,
                chainOffset: chainOffset,
                pagesFileSlice: pagesFileSlice,
                fileOffset: bytes.fileOffset,
                of: startsInSegment
            )
        }

        return nil
    }
    private func walkChainAndFindPointer(
        for targetOffset: UInt64,
        chainOffset: Int,
        pagesFileSlice: FileSlice,
        fileOffset: Int,
        of startsInSegment: DyldChainedStartsInSegment
    ) -> DyldChainedFixupPointer? {
        guard let pointerFormat = startsInSegment.pointerFormat else {
            return nil
        }
        var chainOffset = chainOffset

        let stride = pointerFormat.stride
        var stop = false
        var chainEnd = false

        while !stop && !chainEnd {
            guard let fixupInfo = _fixupInfo(
                at: chainOffset,
                in: pagesFileSlice,
                pointerFormat: pointerFormat
            ) else {
                stop = true
                continue
            }

            let pointerOffset = fileOffset + chainOffset

            if pointerOffset == targetOffset {
                return DyldChainedFixupPointer(
                    offset: pointerOffset,
                    fixupInfo: fixupInfo
                )
            }

            if fixupInfo.next == 0 {
                chainEnd = true
            } else {
                chainOffset += stride * fixupInfo.next
            }
        }

        return nil
    }
}

extension MachOFile.DyldChainedFixups {
    /// Where the pages of one segment's chains lie in the file.
    private struct ChainBytes {
        /// Offset from the Mach-O header of the segment's first page. Every
        /// `DyldChainedFixupPointer.offset` counts from the same place.
        let fileOffset: Int
        /// How many of the pages' bytes the file holds.
        let length: Int
        let fileSlice: FileSlice?
    }

    /// `segment_offset` is an offset in memory from the image's load address,
    /// and a segment can lie elsewhere in the file: one that ends in zero
    /// fill takes up less of the file than of memory, so those after it are
    /// stored closer to the header than they load. The file offset is the
    /// matching segment's, and `page_count` can cover more than the segment
    /// stores, the zero fill included.
    ///
    /// `nil` when no segment, or more than one, starts at `segment_offset`:
    /// nothing can be said of a chain whose pages are not known. In a dyld
    /// cache image a segment's `fileOffset` counts from the cache, so offsets
    /// from the header are kept as they were.
    private func chainBytes(
        of startsInSegment: DyldChainedStartsInSegment,
        pageCount: Int,
        in machO: MachOFile
    ) -> ChainBytes? {
        let pagesLength = pageCount * numericCast(startsInSegment.page_size)
        var fileOffset: Int = numericCast(startsInSegment.segment_offset)
        var length = pagesLength
        if !machO.isLoadedFromDyldCache {
            guard let loadAddress = machO.preferredLoadAddress else { return nil }
            let segments = machO.segments.filter {
                let (offset, overflow) = UInt64($0.virtualMemoryAddress)
                    .subtractingReportingOverflow(loadAddress)
                return !overflow && $0.virtualMemorySize > 0
                    && offset == startsInSegment.segment_offset
            }
            guard segments.count == 1, let segment = segments.first else { return nil }
            fileOffset = segment.fileOffset
            length = min(pagesLength, segment.fileSize)
        }
        return .init(
            fileOffset: fileOffset,
            length: length,
            fileSlice: try? machO.fileHandle.fileSlice(
                offset: machO.headerStartOffset + fileOffset,
                length: length
            )
        )
    }

    @inline(__always)
    private func _fixupInfo(
        at offset: Int,
        in pagesFileSlice: FileSlice,
        pointerFormat: DyldChainedFixupPointerFormat
    ) -> DyldChainedFixupPointerInfo? {
        if pointerFormat.is64Bit {
//            faster than below code
//            let rawValue = data.advanced(by: offset).withUnsafeBytes {
//                $0.load(as: UInt64.self)
//            }
            guard let rawValue: UInt64 = try? pagesFileSlice.read(
                offset: offset,
                as: UInt64.self
            ) else {
                return nil
            }
            return .init(rawValue: rawValue, pointerFormat: pointerFormat)
        } else {
            guard let rawValue: UInt32 = try? pagesFileSlice.read(
                offset: offset
            ) else {
                return nil
            }
            return .init(rawValue: rawValue, pointerFormat: pointerFormat)
        }
    }
}
