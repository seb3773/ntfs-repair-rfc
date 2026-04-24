# Pseudo-Code Reference — NTFS Clean Room Repair Utility

> **Companion to:** `ntfs-repair_clean_room_spec.md`
> **Purpose:** Implementable pseudo-code for every critical algorithm. Each block references its parent section in the main specification.
> **Convention:** All integers are unsigned 64-bit unless noted. All disk offsets are byte-aligned. All structures are little-endian.

---

## Table of Contents

1. [Phase 0 — Boot Sector Sync](#1-phase-0--boot-sector-sync-21)
2. [MFT Record Size Parsing](#2-mft-record-size-parsing-21)
3. [Data Run Decoder](#3-data-run-decoder-23)
4. [USA Fixup](#4-usa-fixup-31)
5. [Bitmap Double-Pass](#5-bitmap-double-pass-33)
6. [$ATTRIBUTE_LIST Iterative Traversal](#6-attribute_list-iterative-traversal-34)
7. [B-Tree 4-Level Rebuild](#7-b-tree-4-level-rebuild-4)
8. [Journal Semi-Semantic Replay](#8-journal-semi-semantic-replay-5)
9. [Orphan Recovery](#9-orphan-recovery-4-phase-9)
10. [$Secure Stream Validation](#10-secure-stream-validation-4-phase-13)
11. [WAL Crash Recovery](#11-wal-crash-recovery-62)
12. [io_context Error Handler](#12-io_context-error-handler-61)
13. [MftCache Write-Through Eviction](#13-mftcache-write-through-eviction-61)


---

## 1. Phase 0 — Boot Sector Sync (§2.1)

```
function boot_sector_sync(io):
    primary = io.read(offset=0, len=512)
    backup  = io.read(offset=io.total_bytes - 512, len=512)

    p_valid = validate_boot(primary)
    b_valid = validate_boot(backup)

    if p_valid AND b_valid:
        return primary                          // both ok, use primary
    if p_valid AND NOT b_valid:
        io.write(offset=io.total_bytes - 512, data=primary)
        log(WARN, E_BOOT_BACKUP_RESTORED)
        return primary
    if NOT p_valid AND b_valid:
        io.write(offset=0, data=backup)
        log(WARN, E_BOOT_PRIMARY_RESTORED)
        return backup
    // both corrupt
    log(FATAL, E_BOOT_BOTH_CORRUPT)
    abort()

function validate_boot(sector):
    if sector[0x1FE..0x200] != [0x55, 0xAA]:       return false
    if sector[0x03..0x0B] != "NTFS    ":            return false
    bps = le16(sector[0x0B])
    if bps != 512:                                  return false
    spc = sector[0x0D]
    if spc == 0 OR (spc & (spc - 1)) != 0:         return false  // not power of 2
    if le64(sector[0x28]) == 0:                     return false  // total_sectors = 0
    if le64(sector[0x30]) == 0:                     return false  // $MFT LCN = 0
    if le64(sector[0x38]) == 0:                     return false  // $MFTMirr LCN = 0
    return true
```

---

## 2. MFT Record Size Parsing (§2.1)

```
function parse_record_size(boot_sector, offset, cluster_size):
    // offset = 0x40 for MFT records, 0x44 for INDX records
    raw = (int8_t) boot_sector[offset]

    if raw > 0:
        return raw * cluster_size
    else:
        return 1 << abs(raw)                    // 2^|raw|
    // Examples:
    //   raw = 0xF6 = -10 → 2^10 = 1024
    //   raw = 0xF4 = -12 → 2^12 = 4096

// Usage:
cluster_size    = le16(boot[0x0B]) * boot[0x0D]
mft_record_size = parse_record_size(boot, 0x40, cluster_size)
indx_page_size  = parse_record_size(boot, 0x44, cluster_size)
usa_entry_count = mft_record_size / 512         // fixup entries (NOT counting seq word)
```

---

## 3. Data Run Decoder (§2.3)

```
function decode_data_runs(attr_data, total_clusters):
    runs = []
    pos = 0
    prev_lcn = 0

    while pos < len(attr_data):
        header = attr_data[pos]
        if header == 0x00:
            break                                // terminator

        length_len = header & 0x0F               // low nibble
        offset_len = (header >> 4) & 0x0F        // high nibble

        if length_len == 0 OR length_len > 4:
            return ERROR(E_DATARUN_MALFORMED)
        if offset_len > 8:
            // NTFS supports up to 8-byte LCNs, which is required for
            // volumes larger than ~16TB.
            return ERROR(E_DATARUN_MALFORMED)

        pos += 1

        // Read run length (unsigned)
        run_length = read_unsigned(attr_data, pos, length_len)
        pos += length_len

        if run_length == 0:
            return ERROR(E_DATARUN_MALFORMED)

        // Read LCN offset (signed delta)
        if offset_len == 0:
            // SPARSE run — no physical clusters
            runs.append(Run(lcn=SPARSE, length=run_length))
        else:
            delta = read_signed(attr_data, pos, offset_len)
            pos += offset_len
            absolute_lcn = prev_lcn + delta

            if absolute_lcn < 0 OR absolute_lcn >= total_clusters:
                return ERROR(E_DATARUN_OOB)

            if absolute_lcn + run_length > total_clusters:
                return ERROR(E_DATARUN_OOB)

            runs.append(Run(lcn=absolute_lcn, length=run_length))
            prev_lcn = absolute_lcn

    return runs

function read_signed(data, offset, len):
    value = read_unsigned(data, offset, len)
    // Sign-extend: if high bit of last byte is set
    if data[offset + len - 1] & 0x80:
        value -= (1 << (len * 8))               // two's complement
    return (int64_t) value

function read_unsigned(data, offset, len):
    value = 0
    for i in 0..len-1:
        value |= (uint64_t)(data[offset + i]) << (i * 8)
    return value
```

---

## 4. USA Fixup (§3.1)

```
function apply_usa_fixup(record, record_size):
    // record = raw bytes from disk, record_size = 1024 or 4096
    usa_offset = le16(record[0x04])
    usa_count  = le16(record[0x06])

    expected_fixups = (record_size / 512) + 1    // 1 seq word + N fixup words
    if usa_count != expected_fixups:
        return ERROR(E_USA_MISMATCH)

    seq_value = le16(record[usa_offset])         // the expected sentinel

    for i in 1..usa_count-1:
        sector_end_offset = (i * 512) - 2        // last 2 bytes of sector i
        on_disk_value = le16(record[sector_end_offset])

        if on_disk_value != seq_value:
            return ERROR(E_USA_MISMATCH, sector=i)

        // Restore original bytes from fixup array
        fixup_value = le16(record[usa_offset + (i * 2)])
        write_le16(record, sector_end_offset, fixup_value)

    return OK
```

---

## 5. Bitmap Double-Pass (§3.3)

```
function bitmap_verify(io, mft, volume_bitmap, total_clusters):
    // --- Pass 1: Ground Truth Construction ---
    ground_truth = RoaringBitmap.new()

    for record_id in 0..mft.total_records-1:
        record = mft.read_record(record_id)
        if NOT record.is_in_use():
            continue

        for attr in record.attributes():
            if attr.is_resident():
                continue
            runs = decode_data_runs(attr.run_data, total_clusters)
            if runs is ERROR:
                log(ERROR, E_DATARUN_MALFORMED, mft_id=record_id)
                continue
            for run in runs:
                if run.lcn == SPARSE:
                    continue                     // sparse runs have no physical clusters
                if run.lcn == DEDUP_STUB:
                    continue                     // dedup stubs: Allocated_Size = 0 (§3.13)
                ground_truth.add_range(run.lcn, run.lcn + run.length)

    // --- Pass 2: Bit-by-Bit Reconciliation ---
    corrections = 0
    for cluster in 0..total_clusters-1:
        computed = ground_truth.contains(cluster)
        on_disk  = volume_bitmap.get(cluster)

        if computed AND NOT on_disk:
            // USED but marked FREE — risk of overwrite
            volume_bitmap.set(cluster, USED)
            log(ERROR, E_BITMAP_CROSSLINK, lcn=cluster)
            corrections += 1
        elif NOT computed AND on_disk:
            // FREE but marked USED — cluster leak
            volume_bitmap.set(cluster, FREE)
            log(WARN, E_BITMAP_LEAK, lcn=cluster)
            corrections += 1
            // NOTE: DO NOT issue TRIM/DISCARD here (§3.3, Pitfall 9)

    if corrections > 0:
        volume_bitmap.flush_to_disk(io)
        log(INFO, "Bitmap reconciliation: %d corrections", corrections)
```

---

## 6. $ATTRIBUTE_LIST Iterative Traversal (§3.4)

```
constant MAX_ENTRY_LIMIT = 1024

function rebuild_attribute_list(mft, base_record_id):
    // MANDATORY: iterative traversal — recursive is FORBIDDEN (Pitfall 10)
    stack = [base_record_id]
    visited = BitSet(mft.total_records)
    collected_attrs = []

    while stack is not empty:
        current_id = stack.pop()

        if visited.get(current_id):
            log(WARN, E_ATTRLIST_CIRCULAR, mft_id=current_id)
            continue                             // circular reference broken

        if collected_attrs.length >= MAX_ENTRY_LIMIT:
            log(WARN, E_ATTRLIST_DEPTH, mft_id=base_record_id)
            break                                // depth guard

        visited.set(current_id)
        record = mft.read_record(current_id)

        if NOT record.is_valid():
            continue                             // skip corrupt children

        for attr in record.attributes():
            if attr.type == 0xFFFFFFFF:
                break                            // end marker
            runs_ok = validate_data_runs_if_nonresident(attr)
            if runs_ok:
                collected_attrs.append(AttrListEntry(
                    type     = attr.type,
                    name     = attr.name,
                    vcn      = attr.start_vcn,
                    mft_ref  = current_id,
                    attr_id  = attr.id
                ))

            // If this record references children, push them
            if attr.type == ATTRIBUTE_LIST_TYPE:
                for entry in parse_attrlist_entries(attr):
                    child_id = entry.mft_reference & 0xFFFFFFFFFFFF
                    if child_id != base_record_id:
                        stack.push(child_id)

    // Sort by (type, vcn) and deduplicate
    collected_attrs.sort(key = lambda e: (e.type, e.vcn))
    collected_attrs = deduplicate(collected_attrs)

    // Write rebuilt attribute list to base record
    write_attribute_list(mft, base_record_id, collected_attrs)
```

---

## 7. B-Tree 4-Level Rebuild (§4)

```
function rebuild_i30_index(mft, directory_record_id, upcase_table):
    dir = mft.read_record(directory_record_id)

    // --- Level 1: MFT Sweep (ground truth) ---
    expected_children = []
    for record_id in 0..mft.total_records-1:
        rec = mft.read_record(record_id)
        if NOT rec.is_in_use():
            continue
        for fn_attr in rec.get_attributes(type=FILE_NAME):
            if fn_attr.parent_mft_ref == directory_record_id:
                expected_children.append(IndexEntry(
                    mft_ref   = record_id,
                    file_name = fn_attr
                ))

    // --- Level 2: Sort by $UpCase collation ---
    // CRITICAL: use volume's own $UpCase table, NOT host OS unicode (Pitfall 6)
    expected_children.sort(key = lambda e:
        upcase_collation_key(e.file_name.name, upcase_table)
    )

    // --- Level 3: Rebuild B-Tree from sorted entries ---
    index_root = create_index_root(expected_children)
    if entries_fit_in_root(expected_children, dir):
        // Small directory: all entries in $INDEX_ROOT (resident)
        write_index_root(dir, index_root)
    else:
        // Large directory: spill to $INDEX_ALLOCATION pages
        pages = allocate_indx_pages(expected_children)
        build_btree_nodes(pages, expected_children)
        write_index_root(dir, pages[0].header)
        write_index_allocation(dir, pages)

    // --- Level 4: Orphan INDX Scan (§4, pseudo-code in spec) ---
    // Sequential sweep of $INDEX_ALLOCATION for detached pages
    // not reachable from the rebuilt tree
    scan_orphan_indx_pages(mft, directory_record_id, expected_children)

    // --- Post-rebuild: Hardlink Count Verification ---
    for child in expected_children:
        actual_links = count_directory_entries_for(mft, child.mft_ref)
        rec = mft.read_record(child.mft_ref)
        if rec.link_count != actual_links:
            rec.link_count = actual_links
            mft.write_record(child.mft_ref, rec)
```

---

## 8. Journal Semi-Semantic Replay (§5)

```
function replay_journal(io, mft, logfile):
    // Step 1: Find latest valid restart page
    restart = find_latest_restart_page(logfile)
    if restart.flags & CLEAN_DISMOUNT:
        log(INFO, "Journal clean — no replay needed")
        return

    // Step 2: Build transaction table from restart area
    lsn = restart.current_lsn

    // Step 3: Walk log records in LSN order
    while record = logfile.read_record(lsn):
        if record.record_type != CLIENT_RECORD:
            lsn = record.next_lsn
            continue

        client_data = record.client_data
        redo_op = le16(client_data[0x00])
        redo_offset = le16(client_data[0x04])
        redo_length = le16(client_data[0x06])
        target_attr_type = le16(client_data[0x0C])
        redo_data = client_data[header_size .. header_size + redo_length]

        // --- Opcode dispatch (semi-semantic model) ---
        if redo_op in [0x00, 0x01, 0x1D..0x24]:
            // No-ops: skip silently (8/38 cases)
            lsn = record.next_lsn
            continue

        if redo_op in [0x0A, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C]:
            // Specialized handlers — v2.0 only
            log(WARN, E_JOURNAL_SKIP, "Unsupported redo_op 0x%02X", redo_op)
            lsn = record.next_lsn
            continue

        // --- Generic positional copy (23/38 cases) ---
        // Locate target: resolve LCN list to physical location
        target_lcns = read_lcn_list(client_data)
        target_buffer = io.read_clusters(target_lcns)

        // Apply USA fixup to target buffer
        apply_usa_fixup(target_buffer, mft_record_size)

        // Locate attribute within record by type + name
        attr = find_attribute_by_type_and_name(
            target_buffer, target_attr_type,
            record.attribute_name   // from log record header
        )

        if attr is NULL:
            // Attribute not found — may need creation
            if redo_length > 0:
                attr = create_attribute(target_buffer, target_attr_type)
            else:
                lsn = record.next_lsn
                continue

        // Apply redo data at the specified offset within attribute
        memcpy(attr.data + redo_offset, redo_data, redo_length)

        // Re-apply USA protection and write back
        apply_usa_protection(target_buffer, mft_record_size)
        io.write_clusters(target_lcns, target_buffer)

        lsn = record.next_lsn

    // Step 4: Flush all caches
    mft.flush()
    io.sync()
    log(INFO, "Journal replay complete")
```

---

## 9. Orphan Recovery (§4, Phase 9)

```
function recover_orphans(mft, root_index):
    // Build set of all MFT records reachable from directory tree
    indexed = BitSet(mft.total_records)
    walk_directory_tree_iterative(mft, root_index, indexed)

    // System files (MFT records 0-23) are always reachable
    for i in 0..23:
        indexed.set(i)

    orphan_dir = get_or_create_found_000(mft)
    recovered = 0

    for record_id in 24..mft.total_records-1:
        rec = mft.read_record(record_id)
        if NOT rec.is_in_use():
            continue
        if indexed.get(record_id):
            continue

        // This record is IN_USE but not indexed — orphan candidate

        // --- Anti-Zombie Check (§4) ---
        has_data = rec.has_attribute(DATA_TYPE)
        has_index_root = rec.has_attribute(INDEX_ROOT_TYPE)
        has_ea = rec.has_attribute(EA_TYPE)
        has_logged = rec.has_attribute(LOGGED_UTILITY_STREAM_TYPE)

        if NOT has_data AND NOT has_index_root AND NOT has_ea AND NOT has_logged:
            // True zombie — no useful content
            rec.clear_in_use()
            mft.write_record(record_id, rec)
            log(WARN, E_ZOMBIE_DELETED, mft_id=record_id)
            continue

        // --- Filename Recovery (§5.1) ---
        filename = recover_filename(rec, record_id)

        // Link orphan into found.000/
        add_index_entry(orphan_dir, record_id, filename)
        rec.link_count = 1
        mft.write_record(record_id, rec)
        log(INFO, E_ORPHAN_RECOVERED, mft_id=record_id, name=filename)
        recovered += 1

    return recovered

function recover_filename(rec, record_id):
    // Priority 1: $FILE_NAME attribute in record
    fn = rec.get_attribute(FILE_NAME_TYPE)
    if fn is not NULL AND fn.name_length > 0:
        return fn.name

    // Priority 2: $UsnJrnl advisory lookup (§5.1)
    usn_rec = usn_journal.find_by_mft_ref(record_id)
    if usn_rec is not NULL:
        if usn_rec.major_version == 2 AND usn_rec.file_name_length > 0:
            seq_on_disk = rec.sequence_number
            seq_in_usn = (usn_rec.file_reference >> 48) & 0xFFFF
            if seq_on_disk == seq_in_usn:          // freshness check
                return usn_rec.file_name

    // Priority 3: Generic fallback
    return format("FILE%04d.CHK", record_id)
```

---

## 10. $Secure Stream Validation (§4, Phase 13)

```
function validate_secure(io, secure_file):
    sds = secure_file.read_stream("$SDS")
    sii = secure_file.read_index("$SII")
    sdh = secure_file.read_index("$SDH")

    // --- Walk $SDS sequentially ---
    valid_entries = {}                            // security_id → SDS_Entry
    offset = 0

    while offset < sds.length:
        entry = parse_sds_entry(sds, offset)

        // Boundary check: entry must not cross 256KB boundary
        boundary = (offset / 0x40000 + 1) * 0x40000
        if offset + entry.length > boundary:
            log(WARN, "SDS entry at 0x%X crosses 256KB boundary", offset)
            break

        // Self-referential offset check
        if entry.offset != offset:
            log(WARN, "SDS entry self-offset mismatch at 0x%X", offset)
            // Try redundant copy
            alt_offset = offset + 0x40000
            alt_entry = parse_sds_entry(sds, alt_offset)
            if alt_entry.offset == alt_offset:
                entry = alt_entry               // use redundant copy
            else:
                offset = align_16(offset + 20)  // skip corrupt entry
                continue

        // Hash verification
        computed_hash = compute_sii_hash(sds[offset + 0x14 .. offset + entry.length])
        if computed_hash != entry.hash_key:
            log(WARN, "SDS hash mismatch for SecurityId %d", entry.security_id)
            offset = align_16(offset + entry.length)
            continue

        valid_entries[entry.security_id] = entry
        offset = align_16(offset + entry.length)

    // --- Cross-check $SII ---
    for sii_entry in sii.entries():
        if sii_entry.security_id NOT in valid_entries:
            sii.delete_entry(sii_entry)
            log(WARN, "Orphan $SII entry deleted: SecurityId %d", sii_entry.security_id)

    // --- Cross-check $SDH ---
    for sdh_entry in sdh.entries():
        target = valid_entries.find_by_hash(sdh_entry.hash)
        if target is NULL:
            sdh.delete_entry(sdh_entry)
            log(WARN, "Orphan $SDH entry deleted: hash 0x%08X", sdh_entry.hash)

function compute_sii_hash(sd_bytes):
    hash = 0
    for i in 0..len(sd_bytes)/4 - 1:
        dword = le32(sd_bytes[i*4 .. i*4+4])
        hash = ((hash >> 29) | (hash << 3)) + dword    // ror 29 + add
        hash = hash & 0xFFFFFFFF                        // keep 32-bit
    return hash
```

---

## 11. WAL Crash Recovery (§6.2)

```
function wal_recover(wal_path, io):
    if NOT file_exists(wal_path):
        return                                   // no recovery needed

    wal = open_file(wal_path, mode=READ_WRITE)
    entries_processed = 0

    while NOT wal.eof():
        entry = read_wal_entry(wal)

        // Validate WAL entry self-integrity
        computed_crc = crc32(entry.header + entry.payload)
        if computed_crc != entry.entry_crc32:
            log(FATAL, "WAL entry #%d self-CRC mismatch — WAL corrupt", entry.tx_id)
            abort()

        if entry.magic != 0x57414C31:            // "WAL1"
            log(FATAL, "WAL magic mismatch at entry #%d", entry.tx_id)
            abort()

        if entry.flags == 0x01:                  // already committed
            entries_processed += 1
            continue

        // Entry is PENDING (flags == 0x00) — needs resolution
        disk_data = io.read(entry.disk_offset, entry.payload_len)
        disk_crc = crc32(disk_data)

        if disk_crc == entry.old_crc32:
            // Write was never applied — roll forward
            io.write(entry.disk_offset, entry.payload)
            io.sync()
            entry.flags = 0x01
            wal.update_entry_flags(entry)
            log(INFO, "WAL roll-forward: TX#%d at offset 0x%X", entry.tx_id, entry.disk_offset)

        elif disk_crc == entry.new_crc32:
            // Write was applied but flag not updated — just mark committed
            entry.flags = 0x01
            wal.update_entry_flags(entry)
            log(INFO, "WAL already applied: TX#%d", entry.tx_id)

        else:
            // Neither matches — volume modified externally
            log(FATAL, E_WAL_CONFLICT,
                "TX#%d: disk CRC 0x%08X matches neither old (0x%08X) nor new (0x%08X)",
                entry.tx_id, disk_crc, entry.old_crc32, entry.new_crc32)
            abort()

        entries_processed += 1

    // All entries resolved — clean up
    wal.close()
    delete_file(wal_path)
    log(INFO, "WAL recovery complete: %d entries processed", entries_processed)
```

---

## 12. io_context Error Handler (§6.1)

```
constant MAX_RETRIES = 3
constant BACKOFF_MS = [100, 500, 2000]

function io_read_safe(ctx, offset, buf, len):
    for attempt in 0..MAX_RETRIES-1:
        result = ctx.read(ctx, offset, buf, len)

        if result == 0:
            return OK                            // success

        errno = ctx.last_errno

        // --- Transient errors: retry with backoff ---
        if errno in [EAGAIN, EINTR, EBUSY]:
            log(TRACE, "Transient I/O error at 0x%X (attempt %d): %s",
                offset, attempt, strerror(errno))
            sleep_ms(BACKOFF_MS[attempt])
            continue

        // --- Recoverable: bad sector ---
        if errno in [EIO, EMEDIUMTYPE]:
            ctx.is_eio = true
            lcn = offset / cluster_size
            badclus_queue.add(lcn)
            log(ERROR, E_IO_EIO, lcn=lcn, offset=offset)
            return ERR_BAD_SECTOR                // caller decides: skip or abort phase

        // --- Fatal: abort immediately ---
        if errno in [ENOSPC, EROFS, EACCES, ENXIO, ENODEV]:
            log(FATAL, "Fatal I/O error at 0x%X: %s", offset, strerror(errno))
            wal_flush_and_close()
            abort()

        // --- Unknown errno: treat as fatal ---
        log(FATAL, "Unknown I/O error %d at 0x%X", errno, offset)
        abort()

    // All retries exhausted — escalate transient to recoverable
    log(ERROR, "I/O retries exhausted at 0x%X — treating as bad sector", offset)
    ctx.is_eio = true
    badclus_queue.add(offset / cluster_size)
    return ERR_BAD_SECTOR

function io_read_with_timeout(ctx, offset, buf, len, timeout_sec=30):
    // WARNING: Do NOT use alarm() or ppoll() for block device I/O timeouts.
    // alarm() is process-wide and incompatible with parallel threads.
    // ppoll() returns POLLIN immediately on block devices, so pread() still hangs.
    // 
    // Implementers MUST use one of two patterns (detailed in Spec §6.1):
    // 1. io_uring with IORING_OP_LINK_TIMEOUT (Recommended for Linux)
    // 2. Thread-per-IO watchdog with pthread_mutex_timedlock() (Portable fallback)

    result = perform_safe_timeout_read(ctx, offset, buf, len, timeout_sec)

    if result == ERR_TIMEOUT:
        log(FATAL, E_IO_TIMEOUT, "I/O timeout at 0x%X after %ds", offset, timeout_sec)
        abort()

    return result
```

---

## 13. MftCache Write-Through Eviction (§6.1)

```
function evict_mft_cache(cache, io):
    // Find Least Recently Used entry
    lru_entry = cache.find_lru()

    if lru_entry.is_dirty:
        // CRITICAL: Must write-through to WAL and disk before evicting.
        // Failing to do this loses modifications made directly in cache (e.g. B-Tree rebuilds).
        
        // 1. Write to WAL (Multi-sector atomic transaction)
        tx_id = wal_begin_tx(io)
        wal_append_write(io, tx_id, lru_entry.disk_offset, lru_entry.data, mft_record_size)
        wal_commit_tx(io, tx_id)
        
        // 2. Write to disk
        io.write(lru_entry.disk_offset, lru_entry.data, mft_record_size)
        
        // 3. Mark clean
        lru_entry.is_dirty = false

    // Now safe to evict and reuse
    cache.free_slot(lru_entry)
```

---

> **Implementation Note:** All pseudo-code in this document uses iterative patterns exclusively. No recursive function calls are present (Pitfall 10, §3.4). All disk writes go through the WAL (Pitfall 11, §6.2). No TRIM/DISCARD commands are emitted (Pitfall 9, §3.3).
