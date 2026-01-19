const std = @import("std");
const macho = std.macho;

pub const Extractor = struct {
    allocator: std.mem.Allocator,
    file_bytes: []const u8,

    pub const ExtractionResult = struct {
        name: []const u8,
        code: []const u8,
        relocations: []const Relocation,
    };

    pub const Relocation = struct {
        offset: u32,
        type: u4,
        symbol_name: ?[]const u8,
        pcrel: bool,
        length: u2,
    };

    // Mach-O Constants
    const MH_MAGIC_64 = 0xfeedfacf;
    const LC_SYMTAB = 0x2;
    const LC_SEGMENT_64 = 0x19;

    pub fn init(allocator: std.mem.Allocator, file_bytes: []const u8) Extractor {
        return .{
            .allocator = allocator,
            .file_bytes = file_bytes,
        };
    }

    pub fn extractAll(self: *Extractor, prefix: []const u8) ![]ExtractionResult {
        var results = std.ArrayListUnmanaged(ExtractionResult){};
        // We do not defer results.deinit() because we return the owned slice.
        // Caller must free the slice.

        const header = try self.getHeader();
        if (header.magic != MH_MAGIC_64) return error.InvalidMagic;

        // 1. Find Symtab
        var symtab_cmd: ?*const macho.symtab_command = null;
        var cmd_iter = self.getLoadCommandsIterator(header);
        while (cmd_iter.next()) |cmd| {
            if (@intFromEnum(cmd.cmd) == LC_SYMTAB) {
                symtab_cmd = @ptrCast(@alignCast(cmd));
                break;
            }
        }
        if (symtab_cmd == null) return error.SymtabNotFound;
        const symtab = symtab_cmd.?;

        // 2. Iterate Symbols
        const str_base = symtab.stroff;
        const sym_base = symtab.symoff;

        var i: u32 = 0;
        while (i < symtab.nsyms) : (i += 1) {
            const sym_offset = sym_base + (i * @sizeOf(macho.nlist_64));
            const sym: *const macho.nlist_64 = @ptrCast(@alignCast(self.file_bytes.ptr + sym_offset));

            const str_offset = str_base + sym.n_strx;
            const sym_name = std.mem.sliceTo(self.file_bytes[str_offset..], 0);

            // Check prefix (handling Mach-O underscore)
            // If prefix is "stencil_", we look for "_stencil_"
            if (sym_name.len > 1 and sym_name[0] == '_') {
                if (std.mem.startsWith(u8, sym_name[1..], prefix)) {
                    const name_without_underscore = sym_name[1..];

                    // Avoid duplicates or extraction of symbols that are not functions (if any)
                    // Check N_TYPE == N_SECT (0xe)
                    if ((sym.n_type & 0xe) != 0xe) continue;

                    // Extract using the symbol pointer directly to avoid re-lookup
                    const res = try self.extractFromSymbol(sym, name_without_underscore);
                    try results.append(self.allocator, res);
                }
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn extract(self: *Extractor, symbol_name: []const u8) !ExtractionResult {
        // Fallback to name lookup
        const header = try self.getHeader();
        if (header.magic != MH_MAGIC_64) return error.InvalidMagic;

        var symtab_cmd: ?*const macho.symtab_command = null;
        var cmd_iter = self.getLoadCommandsIterator(header);
        while (cmd_iter.next()) |cmd| {
            if (@intFromEnum(cmd.cmd) == LC_SYMTAB) symtab_cmd = @ptrCast(@alignCast(cmd));
        }
        if (symtab_cmd == null) return error.SymtabNotFound;
        const symtab = symtab_cmd.?;

        const search_name = try std.fmt.allocPrint(self.allocator, "_{s}", .{symbol_name});
        defer self.allocator.free(search_name);

        const symbol = try self.findSymbol(symtab, search_name);
        return self.extractFromSymbol(symbol, symbol_name);
    }

    fn extractFromSymbol(self: *Extractor, sym: *const macho.nlist_64, name: []const u8) !ExtractionResult {
        const header = try self.getHeader();

        // 1. Find Text Section
        var text_section: ?*const macho.section_64 = null;
        var cmd_iter = self.getLoadCommandsIterator(header);
        while (cmd_iter.next()) |cmd| {
            if (@intFromEnum(cmd.cmd) == LC_SEGMENT_64) {
                const seg: *const macho.segment_command_64 = @ptrCast(@alignCast(cmd));
                var section_ptr: [*]const u8 = @ptrCast(seg);
                section_ptr += @sizeOf(macho.segment_command_64);
                var i: usize = 0;
                while (i < seg.nsects) : (i += 1) {
                    const sect: *const macho.section_64 = @ptrCast(@alignCast(section_ptr));
                    const sect_name = std.mem.sliceTo(&sect.sectname, 0);
                    if (std.mem.eql(u8, sect_name, "__text")) {
                        text_section = sect;
                    }
                    section_ptr += @sizeOf(macho.section_64);
                }
            }
        }
        if (text_section == null) return error.TextSectionNotFound;
        const text_sect = text_section.?;

        const sym_start = sym.n_value;
        const sect_start = text_sect.addr;
        const sect_end = sect_start + text_sect.size;

        if (sym_start < sect_start or sym_start >= sect_end) {
            return error.SymbolNotInTextSection;
        }

        // 2. Determine Code Bounds
        const code_file_offset = text_sect.offset + (sym_start - sect_start);
        var code_end = sect_end;

        // Need symtab to find next symbol
        var symtab_cmd: ?*const macho.symtab_command = null;
        cmd_iter = self.getLoadCommandsIterator(header);
        while (cmd_iter.next()) |cmd| {
            if (@intFromEnum(cmd.cmd) == LC_SYMTAB) symtab_cmd = @ptrCast(@alignCast(cmd));
        }
        const symtab = symtab_cmd.?; // Should exist
        const sym_base = symtab.symoff;

        var i: u32 = 0;
        while (i < symtab.nsyms) : (i += 1) {
            const s_offset = sym_base + (i * @sizeOf(macho.nlist_64));
            const s: *const macho.nlist_64 = @ptrCast(@alignCast(self.file_bytes.ptr + s_offset));
            if ((s.n_type & 0xe) == 0xe) {
                // Check if it's after our symbol but before current code_end
                if (s.n_value > sym_start and s.n_value < code_end) {
                    code_end = s.n_value;
                }
            }
        }

        const code_len = code_end - sym_start;
        const code = self.file_bytes[code_file_offset .. code_file_offset + code_len];

        // 3. Extract Relocations
        var relocs = std.ArrayListUnmanaged(Relocation){};
        defer relocs.deinit(self.allocator);

        const nreloc = text_sect.nreloc;
        const reloff = text_sect.reloff;

        var r_idx: u32 = 0;
        while (r_idx < nreloc) : (r_idx += 1) {
            const rel_base = reloff + (r_idx * @sizeOf(macho.relocation_info));
            const r_address = std.mem.readInt(i32, self.file_bytes[rel_base..][0..4], .little);
            const r_info = std.mem.readInt(u32, self.file_bytes[rel_base + 4 ..][0..4], .little);

            const offset_in_sect = @as(u32, @bitCast(r_address));

            const func_start_offset = sym_start - sect_start;
            const func_end_offset = code_end - sect_start;

            if (offset_in_sect < func_start_offset or offset_in_sect >= func_end_offset) continue;

            const offset_in_func = offset_in_sect - @as(u32, @truncate(func_start_offset));
            const r_symbolnum = r_info & 0xFFFFFF;
            const r_pcrel = (r_info >> 24) & 1;
            const r_length = (r_info >> 25) & 3;
            const r_extern = (r_info >> 27) & 1;

            var rel_sym_name: ?[]const u8 = null;
            if (r_extern == 1) {
                rel_sym_name = try self.getSymbolName(symtab, r_symbolnum);
            }

            try relocs.append(self.allocator, .{
                .offset = offset_in_func,
                .type = @as(u4, @truncate(r_info >> 28)),
                .symbol_name = rel_sym_name,
                .pcrel = r_pcrel == 1,
                .length = @as(u2, @truncate(r_length)),
            });
        }

        return ExtractionResult{
            .name = name,
            .code = code,
            .relocations = try relocs.toOwnedSlice(self.allocator),
        };
    }

    fn getHeader(self: *Extractor) !*const macho.mach_header_64 {
        if (self.file_bytes.len < @sizeOf(macho.mach_header_64)) return error.EOF;
        return @ptrCast(@alignCast(self.file_bytes.ptr));
    }

    const LoadCommandIterator = struct {
        bytes: []const u8,
        offset: usize,
        count: u32,
        current: u32 = 0,

        pub fn next(self: *LoadCommandIterator) ?*const macho.load_command {
            if (self.current >= self.count) return null;
            if (self.offset >= self.bytes.len) return null;

            const cmd: *const macho.load_command = @ptrCast(@alignCast(self.bytes.ptr + self.offset));
            self.offset += cmd.cmdsize;
            self.current += 1;
            return cmd;
        }
    };

    fn getLoadCommandsIterator(self: *Extractor, header: *const macho.mach_header_64) LoadCommandIterator {
        return .{
            .bytes = self.file_bytes,
            .offset = @sizeOf(macho.mach_header_64),
            .count = header.ncmds,
        };
    }

    fn findSymbol(self: *Extractor, symtab: *const macho.symtab_command, name: []const u8) !*const macho.nlist_64 {
        const str_base = symtab.stroff;
        const sym_base = symtab.symoff;

        var i: u32 = 0;
        while (i < symtab.nsyms) : (i += 1) {
            const sym_offset = sym_base + (i * @sizeOf(macho.nlist_64));
            const sym: *const macho.nlist_64 = @ptrCast(@alignCast(self.file_bytes.ptr + sym_offset));

            const str_offset = str_base + sym.n_strx;
            const sym_name = std.mem.sliceTo(self.file_bytes[str_offset..], 0);

            if (std.mem.eql(u8, sym_name, name)) {
                return sym;
            }
        }
        return error.SymbolNotFound;
    }

    fn getSymbolName(self: *Extractor, symtab: *const macho.symtab_command, symbolnum: u32) ![]const u8 {
        const str_base = symtab.stroff;
        const sym_base = symtab.symoff;

        const sym_offset = sym_base + (symbolnum * @sizeOf(macho.nlist_64));
        const sym: *const macho.nlist_64 = @ptrCast(@alignCast(self.file_bytes.ptr + sym_offset));

        const str_offset = str_base + sym.n_strx;
        return std.mem.sliceTo(self.file_bytes[str_offset..], 0);
    }
};
