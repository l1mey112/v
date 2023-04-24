// Copyright (c) 2023 l-m.dev. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module serialise

import v.ast
// import v.eval
import encoding.binary as bin
import math.bits
import strconv

pub enum Endianness {
	little
	big
}

[noinit]
pub struct Pool {
mut:
	table   &ast.Table
	// eval    eval.Eval
	structs map[ast.Type]StructInfo
	strings []StringInfo // string intern
pub:
	endianness      Endianness
	null_terminated bool
	intern_strings  bool
	store_relocs    bool
pub mut:
	buf    []u8
	relocs []Reloc
}

struct StringInfo {
	pos int
	len int
}

pub struct StructInfo {
pub mut:
	offsets []int
}

pub struct Reloc {
pub:
	pos    int
	offset int
}

fn (mut p Pool) type_struct_info(typ ast.Type) ?StructInfo {
	ts := p.table.sym(typ)

	if ts.info !is ast.Struct {
		return none
	}

	if typ in p.structs {
		return p.structs[typ]
	}

	// will cache inside `p.structs`
	p.type_size(typ)
	return p.structs[typ]
}

fn (mut p Pool) type_size(typ ast.Type) (int, int) {
	ts := p.table.sym(typ)
	if ts.size != -1 && typ in p.structs {
		return ts.size, ts.align
	}

	if ts.info !is ast.Struct {
		return p.table.type_size(typ)
	}

	ti := ts.info as ast.Struct

	// code borrowed from native, inserted in wasm, and now here!

	mut strc := StructInfo{}
	mut size := 0
	mut align := 1
	for f in ti.fields {
		f_size, f_align := p.table.type_size(f.typ)
		if f_size == 0 {
			strc.offsets << 0
			continue
		}
		padding := (f_align - size % f_align) % f_align
		strc.offsets << size + padding
		size += f_size + padding
		if f_align > align {
			align = f_align
		}
	}
	size = (size + align - 1) / align * align
	p.structs[typ.idx()] = strc

	mut ts_ := p.table.sym(typ)
	ts_.size = size
	ts_.align = align

	return size, align
}

[params]
pub struct PoolOpts {
	endianness      Endianness = .little
	null_terminated bool       = true
	intern_strings  bool       = true
	store_relocs    bool       = true
}

pub fn new_pool(table &ast.Table, opts PoolOpts) Pool {
	return Pool{
		table: table
		endianness: opts.endianness
		null_terminated: opts.null_terminated
		intern_strings: opts.intern_strings
		store_relocs: opts.store_relocs
	}
}

fn (mut p Pool) alignment(align int) int {
	padding := (align - p.buf.len % align) % align
	pos := p.buf.len
	for i := 0; i < padding; i++ {
		p.buf << 0
	}
	return pos
}

/*
fn (mut p Pool) append_struct(init ast.StructInit) ?int {
	old_len := p.buf.len

	size, align := p.type_size(v.typ)
	ts := g.table.sym(v.typ)
	ts_info := ts.info as ast.Struct

	pos := p.alignment(align)
	
	if init.fields.len == 0 && !(ts_info.fields.any(it.has_default_expr)) {
		for i := 0 ; i < size ; i++ {
			p.buf << 0
		}
		return pos
	}

	/* for i, f in ts_info.fields {
		field_to_be_set := init.fields.map(it.name).filter(f.name)
	} */

	/* for i, f in ts_info.fields {
		field_to_be_set := init.fields.map(it.name).contains(f.name)

		if !field_to_be_set {
			offset := g.structs[v.typ.idx()].offsets[i]
			offset_var := g.offset(v, f.typ, offset)

			fsize, _ := g.get_type_size_align(f.typ)
			
			if f.has_default_expr {
				g.expr(f.default_expr, f.typ)
				g.set(offset_var)
			} else {
				g.zero_fill(offset_var, fsize)
			}						
		}
	}

	for f in init.fields {
		field := ts.find_field(f.name) or {
			g.w_error('could not find field `${f.name}` on init')
		}
		
		offset := g.structs[v.typ.idx()].offsets[field.i]
		offset_var := g.offset(v, f.expected_type, offset)

		g.expr(f.expr, f.expected_type)
		g.set(offset_var)
	} */

	return pos
}*/

pub fn eval_escape_codes(str_lit ast.StringLiteral) !string {
	if str_lit.is_raw {
		return str_lit.val
	}

	str := str_lit.val
	mut buffer := []u8{}

	mut i := 0
	for i < str.len {
		if str[i] != `\\` {
			buffer << str[i]
			i++
			continue
		}

		// skip \
		i++
		match str[i] {
			`\\`, `'`, `"` {
				buffer << str[i]
				i++
			}
			`a`, `b`, `f` {
				buffer << str[i] - u8(90)
				i++
			}
			`n` {
				buffer << `\n`
				i++
			}
			`r` {
				buffer << `\r`
				i++
			}
			`t` {
				buffer << `\t`
				i++
			}
			`u` {
				i++
				utf8 := strconv.parse_int(str[i..i + 4], 16, 16) or {
					return error('invalid \\u escape code (${str[i..i + 4]})')
				}
				i += 4
				buffer << u8(utf8)
				buffer << u8(utf8 >> 8)
			}
			`v` {
				buffer << `\v`
				i++
			}
			`x` {
				i++
				c := strconv.parse_int(str[i..i + 2], 16, 8) or {
					return error('invalid \\x escape code (${str[i..i + 2]})')
				}
				i += 2
				buffer << u8(c)
			}
			`0`...`7` {
				c := strconv.parse_int(str[i..i + 3], 8, 8) or {
					return error('invalid escape code \\${str[i..i + 3]}')
				}
				i += 3
				buffer << u8(c)
			}
			else {
				return error('invalid escape code \\${str[i]}')
			}
		}
	}

	return buffer.bytestr()
}

pub fn (mut p Pool) append_string(val string) int {
	data := val.bytes()

	if p.intern_strings {
		for str in p.strings {
			if data.len > str.len || (p.null_terminated && data.len != str.len) {
				continue
			}

			// TODO: aggressive string interning if `p.null_terminated`
			if p.buf[str.pos..str.pos + data.len] == data {
				return str.pos
			}
		}
	}

	pos := p.buf.len
	p.buf << data
	if p.null_terminated {
		p.buf << 0
	}

	p.strings << StringInfo{
		pos: pos
		len: data.len
	}

	return pos
}

pub fn (mut p Pool) append(init ast.Expr, typ ast.Type) ?int {
	match init {
		ast.BoolLiteral {
			pos := p.buf.len
			p.buf << u8(init.val)
			return pos
		}
		ast.FloatLiteral {
			assert typ.is_pure_float()

			mut bit_buf := []u8{len: 8}
			match p.endianness {
				.little {
					if typ == ast.f32_type {
						bin.little_endian_put_u32(mut bit_buf, bits.f32_bits(init.val.f32()))
						bit_buf.trim(4)
					} else {
						bin.little_endian_put_u64(mut bit_buf, bits.f64_bits(init.val.f64()))
					}
				}
				.big {
					if typ == ast.f32_type {
						bin.big_endian_put_u32(mut bit_buf, bits.f32_bits(init.val.f32()))
						bit_buf.trim(4)
					} else {
						bin.big_endian_put_u64(mut bit_buf, bits.f64_bits(init.val.f64()))
					}
				}
			}

			pos := p.alignment(bit_buf.len)
			p.buf << bit_buf

			return pos
		}
		ast.IntegerLiteral {
			assert typ.is_pure_int()

			size, align := p.table.type_size(typ)
			pos := p.alignment(align)

			if size == 1 {
				p.buf << u8(init.val.i8())
			} else {
				mut bit_buf := []u8{len: size}

				match p.endianness {
					.little {
						match size {
							2 {
								bin.little_endian_put_u16(mut bit_buf, u16(init.val.i16()))
							}
							4 {
								bin.little_endian_put_u32(mut bit_buf, u32(init.val.int()))
							}
							8 {
								bin.little_endian_put_u64(mut bit_buf, u64(init.val.i64()))
							}
							else {}
						}
					}
					.big {
						match size {
							2 {
								bin.big_endian_put_u16(mut bit_buf, u16(init.val.i16()))
							}
							4 {
								bin.big_endian_put_u32(mut bit_buf, u32(init.val.int()))
							}
							8 {
								bin.big_endian_put_u64(mut bit_buf, u64(init.val.i64()))
							}
							else {}
						}
					}
				}

				p.buf << bit_buf
			}

			return pos
		}
		ast.CharLiteral {
			// 3 extra bytes for improved program correctness, thank me later
			rne := u32(init.val.runes()[0])
			pos := p.alignment(4)
			mut bit_buf := []u8{len: 4}
			match p.endianness {
				.little {
					bin.little_endian_put_u32(mut bit_buf, rne)
				}
				.big {
					bin.big_endian_put_u32(mut bit_buf, rne)
				}
			}
			return pos
		}
		ast.StringLiteral {
			val := eval_escape_codes(init) or { panic('Pool.append: ${err}') }
			str_pos := p.append_string(val)

			if typ != ast.string_type {
				// c'str'
				return str_pos
			}

			_, align := p.table.type_size(ast.string_type)
			tss := p.table.sym(ast.string_type).info as ast.Struct
			pos := p.alignment(align)

			for field in tss.fields {
				match field.name {
					'str' {
						p.ptr(str_pos)
					}
					'len' {
						p.int(val.len)
					}
					'is_lit' {
						p.int(1)
					}
					else {
						panic('ast.string: field `${field.name}` is unknown')
					}
				}
			}

			return pos
		}
		else {
			return none
		}
	}
}

fn (mut p Pool) int(val int) int {
	mut bit_buf := []u8{len: 4}
	pos := p.alignment(4)
	match p.endianness {
		.little {
			bin.little_endian_put_u32(mut bit_buf, u32(val))
		}
		.big {
			bin.little_endian_put_u32(mut bit_buf, u32(val))
		}
	}
	p.buf << bit_buf
	return pos
}

fn (mut p Pool) ptr(offset int) int {
	assert p.table.pointer_size in [4, 8]
	pos := p.alignment(p.table.pointer_size)

	if p.store_relocs {
		p.relocs << Reloc{
			pos: pos
			offset: offset
		}
		return pos
	}

	mut bit_buf := []u8{len: p.table.pointer_size}
	if p.table.pointer_size == 4 {
		match p.endianness {
			.little {
				bin.little_endian_put_u32(mut bit_buf, u32(offset))
			}
			.big {
				bin.little_endian_put_u32(mut bit_buf, u32(offset))
			}
		}
	} else if p.table.pointer_size == 8 {
		match p.endianness {
			.little {
				bin.little_endian_put_u64(mut bit_buf, u64(offset))
			}
			.big {
				bin.little_endian_put_u64(mut bit_buf, u64(offset))
			}
		}
	}
	p.buf << bit_buf
	return pos
}
