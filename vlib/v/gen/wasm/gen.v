module wasm

import v.ast
import v.pref
import v.util
import v.token
import v.errors
import v.eval
import wasm
import os

[heap; minify]
pub struct Gen {
	out_name string
	pref     &pref.Preferences = unsafe { nil } // Preferences shared from V struct
	files    []&ast.File
mut:
	file_path     string // current ast.File path
	warnings      []errors.Warning
	errors        []errors.Error
	table         &ast.Table = unsafe { nil }
	eval          eval.Eval
	enum_vals     map[string]Enum
	//
	mod wasm.Module
	func              wasm.Function
	local_vars        []Var
	return_vars       []Var
	ret_types []ast.Type
	ret_br wasm.LabelIndex
	bp_idx            wasm.LocalIndex = -1 // Base pointer temporary's index for function, if needed (-1 for none)
	sp_global         ?wasm.GlobalIndex
	stack_frame       int // Size of the current stack frame, if needed
	is_leaf_function  bool = true
	structs           map[ast.Type]StructInfo // Cached struct field offsets
	module_import_namespace string
}

struct StructInfo {
mut:
	offsets []int
}

pub fn (mut g Gen) v_error(s string, pos token.Pos) {
	if g.pref.output_mode == .stdout {
		util.show_compiler_message('error:', pos: pos, file_path: g.file_path, message: s)
		exit(1)
	} else {
		g.errors << errors.Error{
			file_path: g.file_path
			pos: pos
			reporter: .gen
			message: s
		}
	}
}

pub fn (mut g Gen) warning(s string, pos token.Pos) {
	if g.pref.output_mode == .stdout {
		util.show_compiler_message('warning:', pos: pos, file_path: g.file_path, message: s)
	} else {
		g.warnings << errors.Warning{
			file_path: g.file_path
			pos: pos
			reporter: .gen
			message: s
		}
	}
}

[noreturn]
pub fn (mut g Gen) w_error(s string) {
	if g.pref.is_verbose {
		print_backtrace()
	}
	util.verror('wasm error', s)
}

fn (g Gen) unpack_type(typ ast.Type) []ast.Type {
	ts := g.table.sym(typ)
	return match ts.info {
		ast.MultiReturn {
			ts.info.types
		}
		else {
			[typ]
		}
	}
}

fn (g Gen) is_param_type(typ ast.Type) bool {
	return !typ.is_ptr() && !g.is_pure_type(typ)
}

fn (mut g Gen) fn_decl(node ast.FnDecl) {
	if node.language in [.js, .wasm] {
		g.w_error('fn_decl: extern not implemented')
	}

	name := if node.is_method {
		'${g.table.get_type_name(node.receiver.typ)}.${node.name}'
	} else {
		node.name
	}

	util.timing_start('${@METHOD}: ${name}')
	defer {
		util.timing_measure('${@METHOD}: ${name}')
	}

	if node.no_body {
		return
	}
	if g.pref.is_verbose {
		// println(term.green('\n${name}:'))
	}
	if node.is_deprecated {
		g.warning('fn_decl: ${name} is deprecated', node.pos)
	}

	mut paraml := []wasm.ValType{cap: node.params.len}
	mut retl := []wasm.ValType{cap: 1}

	// fn ()!       | fn () &IError
	// fn () ?(...) | fn () (..., bool)
	// fn () !(...) | fn () (..., &IError)
	// 
	// fn (...) struct      | fn (_ &struct, ...)
	// fn (...) !struct     | fn (_ &struct, ...) &IError
	// fn (...) (...struct) | fn (...&struct, ...)

	rt := node.return_type
	rts := g.table.sym(rt)
	match rts.info {
		ast.MultiReturn {
			for t in rts.info.types {
				wtyp := g.get_wasm_type(t)
				if g.is_param_type(t) {
					paraml << wtyp
					g.return_vars << Var{
						typ: t
						idx: g.return_vars.len
						is_pointer: true
					}
				} else {
					retl << wtyp
				}
				g.ret_types << t
			}
			if rt.has_flag(.option) {
				retl << .i32_t // bool
			}
		}
		else {
			if rt.idx() != ast.void_type_idx {
				wtyp := g.get_wasm_type(rt)
				if g.is_param_type(rt) {
					paraml << wtyp
					g.return_vars << Var{
						name: '__rval0'
						typ: rt
						is_pointer: true
					}
				} else {
					retl << wtyp
				}
				g.ret_types << rt
			} else if rt.has_flag(.option) {
				g.v_error('returning a void option is forbidden', node.return_type_pos)
			}
		}
	}
	if rt.has_flag(.result) {
		retl << .i32_t // &IError
	}

	for p in node.params {
		typ := g.get_wasm_type(p.typ)
		g.local_vars << Var{
			name: p.name
			typ: p.typ
			idx: g.local_vars.len + g.return_vars.len
			is_pointer: p.typ.is_ptr() || !g.is_pure_type(p.typ)
		}
		paraml << typ
	}
	
	g.func = g.mod.new_function(name, paraml, retl)
	func_start := g.func.patch_pos()
	if node.stmts.len > 0 {
		g.ret_br = g.func.c_block([], retl)
		{
			g.expr_stmts(node.stmts, ast.void_type)
		}
		g.func.c_end(g.ret_br)

		// Setup stack frame.
		// If the function does not call other functions, 
		// a leaf function, the omission of setting the 
		// stack pointer is perfectly acceptable.
		//
		if g.stack_frame != 0 {
			prolouge := g.func.patch_pos()
			{
				g.func.global_get(g.sp())
				g.func.i32_const(g.stack_frame)
				g.func.sub(.i32_t)
				if !g.is_leaf_function {
					g.func.local_tee(g.bp())
					g.func.global_set(g.sp())
				} else {
					g.func.local_set(g.bp())					
				}
			}
			g.func.patch(func_start, prolouge)
			if !g.is_leaf_function {
				g.func.local_get(g.bp())
				g.func.global_set(g.sp())
			}
		}
	}
	g.mod.commit(g.func, false)
	g.local_vars.clear()
	g.return_vars.clear()
	g.ret_types.clear()
	g.bp_idx = -1
	g.sp_global = none
	g.stack_frame = 0
	g.is_leaf_function = true
}

fn (mut g Gen) literal(val string, expected ast.Type) {
	match g.get_wasm_type(expected) {
		.i32_t { g.func.i32_const(val.int()) }
		.i64_t { g.func.i64_const(val.i64()) }
		.f32_t { g.func.f32_const(val.f32()) }
		.f64_t { g.func.f64_const(val.f64()) }
		else { g.w_error('literal: bad type `${expected}`') }
	}
}

fn (mut g Gen) cast(typ ast.Type, expected_type ast.Type) {
	wtyp := g.as_numtype(g.get_wasm_type(ast.mktyp(typ)))
	expected_wtype := g.as_numtype(g.get_wasm_type(expected_type))

	g.func.cast(wtyp, typ.is_signed(), expected_wtype)
}

fn (mut g Gen) expr_with_cast(expr ast.Expr, got_type_raw ast.Type, expected_type ast.Type) {
	if expr is ast.IntegerLiteral {
		g.literal(expr.val, expected_type)
		return
	} else if expr is ast.FloatLiteral {
		g.literal(expr.val, expected_type)
		return
	}

	got_type := ast.mktyp(got_type_raw)
	got_wtype := g.as_numtype(g.get_wasm_type(got_type))
	expected_wtype := g.as_numtype(g.get_wasm_type(expected_type))

	g.expr(expr, got_type)
	g.func.cast(got_wtype, got_type.is_signed(), expected_wtype)
}

fn (mut g Gen) handle_ptr_arithmetic(typ ast.Type) {
	if typ.is_ptr() {
		size, _ := g.get_type_size_align(typ)
		g.func.i32_const(size)
		g.func.mul(.i32_t)
	}
}

fn (mut g Gen) infix_expr(node ast.InfixExpr, expected ast.Type) {
	if node.op in [.logical_or, .and] {
		/* mut exprs := []binaryen.Expression{cap: 2}

		left := g.expr(node.left, node.left_type)

		temporary := g.new_local_temporary_anon(ast.bool_type)
		exprs << binaryen.localset(g.mod, temporary, left)

		cmp := if node.op == .logical_or {
			binaryen.unary(g.mod, binaryen.eqzint32(), binaryen.localget(g.mod, temporary,
				type_i32))
		} else {
			binaryen.localget(g.mod, temporary, type_i32)
		}
		exprs << binaryen.bif(g.mod, cmp, g.expr(node.right, node.right_type), binaryen.localget(g.mod,
			temporary, type_i32))

		return g.mkblock(exprs) */
		assert false
	}

	{
		g.expr(node.left, node.left_type)
	}
	{
		g.expr_with_cast(node.right, node.right_type, node.left_type)
		g.handle_ptr_arithmetic(node.left_type)
	}
	g.infix_from_typ(node.left_type, node.op)

	res_typ := if node.op in [.eq, .ne, .gt, .lt, .ge, .le] {
		ast.bool_type
	} else {
		node.left_type
	}
	g.func.cast(g.as_numtype(g.get_wasm_type(res_typ)), res_typ.is_signed(), g.as_numtype(g.get_wasm_type(expected)))
}

/* 


fn (mut g Gen) literalint(val i64, expected ast.Type) binaryen.Expression {
	match g.get_wasm_type(expected) {
		type_i32 { return binaryen.constant(g.mod, binaryen.literalint32(int(val))) }
		type_i64 { return binaryen.constant(g.mod, binaryen.literalint64(val)) }
		else {}
	}
	g.w_error('literalint: bad type `${*g.table.sym(expected)}`')
}

fn (mut g Gen) literal(val string, expected ast.Type) binaryen.Expression {
	match g.get_wasm_type(expected) {
		type_i32 { return binaryen.constant(g.mod, binaryen.literalint32(val.int())) }
		type_i64 { return binaryen.constant(g.mod, binaryen.literalint64(val.i64())) }
		type_f32 { return binaryen.constant(g.mod, binaryen.literalfloat32(val.f32())) }
		type_f64 { return binaryen.constant(g.mod, binaryen.literalfloat64(val.f64())) }
		else {}
	}
	g.w_error('literal: bad type `${expected}`')
}

fn (mut g Gen) handle_ptr_arithmetic(typ ast.Type, expr binaryen.Expression) binaryen.Expression {
	return if typ.is_ptr() {
		size, _ := g.get_type_size_align(typ)
		binaryen.binary(g.mod, binaryen.mulint32(), expr, g.literalint(size, ast.voidptr_type))
	} else {
		expr
	}
}

fn (mut g Gen) postfix_expr(node ast.PostfixExpr) binaryen.Expression {
	kind := if node.op == .inc { token.Kind.plus } else { token.Kind.minus }

	var := g.get_var_from_expr(node.expr)
	op := g.infix_from_typ(node.typ, kind)

	expr := binaryen.binary(g.mod, op, g.get_or_lea_lop(var, node.typ), g.handle_ptr_arithmetic(node.typ,
		g.literal('0', node.typ)))

	return g.set_var(var, expr, ast_typ: node.typ)
}

fn (mut g Gen) prefix_expr(node ast.PrefixExpr) binaryen.Expression {
	expr := g.expr(node.right, node.right_type)

	return match node.op {
		.minus {
			if node.right_type.is_pure_float() {
				if node.right_type == ast.f32_type_idx {
					binaryen.unary(g.mod, binaryen.negfloat32(), expr)
				} else {
					binaryen.unary(g.mod, binaryen.negfloat64(), expr)
				}
			} else {
				// -val == 0 - val

				if g.get_wasm_type(node.right_type) == type_i32 {
					binaryen.binary(g.mod, binaryen.subint32(), binaryen.constant(g.mod,
						binaryen.literalint32(0)), expr)
				} else {
					binaryen.binary(g.mod, binaryen.subint64(), binaryen.constant(g.mod,
						binaryen.literalint64(0)), expr)
				}
			}
		}
		.not {
			binaryen.unary(g.mod, binaryen.eqzint32(), expr)
		}
		.bit_not {
			// ~val == val ^ -1

			if g.get_wasm_type(node.right_type) == type_i32 {
				binaryen.binary(g.mod, binaryen.xorint32(), expr, binaryen.constant(g.mod,
					binaryen.literalint32(-1)))
			} else {
				binaryen.binary(g.mod, binaryen.xorint64(), expr, binaryen.constant(g.mod,
					binaryen.literalint64(-1)))
			}
		}
		.amp {
			g.lea_var_from_expr(node.right)
		}
		.mul {
			g.deref(expr, node.right_type)
		}
		else {
			// impl deref (.mul), and impl address of (.amp)
			g.w_error('`${node.op}val` prefix expression not implemented')
		}
	}
}

fn (mut g Gen) mknblock(name string, nodes []binaryen.Expression) binaryen.Expression {
	if nodes.len == 0 {
		return binaryen.nop(g.mod)
	}

	g.lbl++
	return binaryen.block(g.mod, '${name}${g.lbl}'.str, nodes.data, nodes.len, type_auto)
}

fn (mut g Gen) mkblock(nodes []binaryen.Expression) binaryen.Expression {
	if nodes.len == 0 {
		return binaryen.nop(g.mod)
	}

	g.lbl++
	return binaryen.block(g.mod, 'BLK${g.lbl}'.str, nodes.data, nodes.len, type_auto)
}

fn (mut g Gen) if_branch(ifexpr ast.IfExpr, idx int) binaryen.Expression {
	curr := ifexpr.branches[idx]

	next := if ifexpr.has_else && idx + 2 >= ifexpr.branches.len {
		g.expr_stmts(ifexpr.branches[idx + 1].stmts, ifexpr.typ)
	} else if idx + 1 >= ifexpr.branches.len {
		unsafe { nil }
	} else {
		g.if_branch(ifexpr, idx + 1)
	}
	return binaryen.bif(g.mod, g.expr(curr.cond, ast.bool_type), g.expr_stmts(curr.stmts,
		ifexpr.typ), next)
}

fn (mut g Gen) if_expr(ifexpr ast.IfExpr) binaryen.Expression {
	return g.if_branch(ifexpr, 0)
}

const wasm_builtins = ['__memory_grow', '__memory_fill', '__memory_copy', '__memory_size',
	'__heap_base']

fn (mut g Gen) wasm_builtin(name string, node ast.CallExpr) binaryen.Expression {
	mut args := []binaryen.Expression{cap: node.args.len}
	for idx, arg in node.args {
		args << g.expr(arg.expr, node.expected_arg_types[idx])
	}

	match name {
		'__memory_grow' {
			return binaryen.memorygrow(g.mod, args[0], c'memory', false)
		}
		'__memory_fill' {
			return binaryen.memoryfill(g.mod, args[0], args[1], args[2], c'memory')
		}
		'__memory_copy' {
			return binaryen.memorycopy(g.mod, args[0], args[1], args[2], c'memory', c'memory')
		}
		'__memory_size' {
			return binaryen.memorysize(g.mod, c'memory', false)
		}
		'__heap_base' {
			return binaryen.globalget(g.mod, c'__heap_base', type_i32)
		}
		else {
			panic('unreachable')
		}
	}
}

[params]
struct AssignOpts {
	op token.Kind = .assign
}

fn (mut g Gen) assign_expr_to_var(address LocalOrPointer, right ast.Expr, expected ast.Type, cfg AssignOpts) binaryen.Expression {
	return match right {
		ast.StructInit {
			if cfg.op !in [.decl_assign, .assign] {
				op := token.assign_op_to_infix_op(cfg.op)
				name := '${g.table.get_type_name(expected)}.${op}'

				// args: [&return, &left, &right]
				args := [g.get_or_lea_lop(address, expected),
					g.get_or_lea_lop(address, expected), g.expr(right, expected)]

				binaryen.call(g.mod, name.str, args.data, args.len, type_none)
			} else {
				g.init_struct(address as Var, right)
			}
		}
		ast.StringLiteral {
			if g.table.sym(expected).info !is ast.Struct {
				offset, _ := g.allocate_string(right)
				return g.set_var(address as Var, g.literalint(offset, ast.int_type))
			}

			var := (address as Var) as Stack

			offset, len := g.allocate_string(right)

			g.mknblock('STRINGINIT', [
				g.set_var_v(Stack{ address: var.address, ast_typ: ast.charptr_type },
					g.literalint(offset, ast.u32_type),
					offset: 0
				),
				g.set_var_v(Stack{ address: var.address, ast_typ: ast.int_type }, g.literalint(len,
					ast.int_type),
					offset: g.table.pointer_size
				),
			])
		}
		ast.ArrayInit {
			var := (address as Var) as Stack
			mut exprs := []binaryen.Expression{}

			if !right.is_fixed {
				g.w_error('wasm backend does not support non fixed arrays yet')
			}
			elm_typ := right.elem_type
			elm_size, _ := g.get_type_size_align(elm_typ)
			mut offset := 0
			if !right.has_val {
				return g.mknblock('ARRAYINIT(ZERO)', [
					g.zero_fill(right.typ, var.address),
				])
			}
			// [10, 15]!
			for e in right.exprs {
				exprs << g.assign_expr_to_var(Var(Stack{
					address: var.address + offset
					ast_typ: elm_typ
				}), e, elm_typ)
				offset += elm_size
			}

			g.mknblock('ARRAYINIT', exprs)
		}
		else {
			initexpr := g.expr(right, expected)

			expr := if cfg.op !in [.decl_assign, .assign] {
				if g.is_pure_type(expected) {
					val := g.get_or_lea_lop(address, expected)
					op := g.infix_from_typ(expected, token.assign_op_to_infix_op(cfg.op))

					binaryen.binary(g.mod, op, val, initexpr)
				} else {
					g.w_error('arith unimplemented or unreachable for struct')
				}
			} else {
				initexpr
			}
			g.set_var(address, expr, ast_typ: expected)
		}
	}
}

fn (mut g Gen) multi_assign_stmt(node ast.AssignStmt) binaryen.Expression {
	if node.has_cross_var {
		g.w_error('complex assign statements are not implemented')
	}

	//
	// Expected to be a `a, b := multi_return()`.
	//

	mut exprs := []binaryen.Expression{cap: node.left.len + 1}

	ret := (node.right[0] as ast.CallExpr).return_type
	wret := g.get_wasm_type(ret)
	temporary := g.new_local_temporary_anon(ret)

	// Set multi return function to temporary, then use `tuple.extract`.
	exprs << binaryen.localset(g.mod, temporary, g.expr(node.right[0], 0))

	for i := 0; i < node.left.len; i++ {
		left := node.left[i]
		typ := node.left_types[i]
		// rtyp := node.right_types[i]

		if left is ast.Ident {
			// `_ = expr`
			if left.kind == .blank_ident {
				continue
			}
			if node.op == .decl_assign {
				g.new_local(left, typ)
			}
		}
		var := g.get_var_from_expr(left)
		popexpr := binaryen.tupleextract(g.mod, binaryen.localget(g.mod, temporary, wret),
			i)
		exprs << g.set_var(var, popexpr)
	}

	return g.mkblock(exprs)
}

fn (mut g Gen) new_for_label(node_label string) string {
	g.lbl++
	label := if node_label != '' {
		node_label
	} else {
		g.lbl.str()
	}
	g.for_labels << label

	return label
}

fn (mut g Gen) pop_for_label() {
	g.for_labels.pop()
}

struct BlockPatch {
mut:
	idx   int
	block binaryen.Expression
} */



fn (mut g Gen) expr(node ast.Expr, expected ast.Type) {
	match node {
		ast.ParExpr, ast.UnsafeExpr {
			g.expr(node.expr, expected)
		}
		/* ast.ArrayInit {
			pos := g.allocate_local_var('_anonarray', node.typ)
			expr := g.assign_expr_to_var(Var(Stack{ address: pos, ast_typ: node.typ }),
				node, node.typ)
			g.mknblock('EXPR(ARRAYINIT)', [expr, g.lea_address(pos)])
		} */
		ast.GoExpr {
			g.w_error('wasm backend does not support threads')
		}
		/* ast.IndexExpr {
			// TODO: IMPLICIT BOUNDS CHECKING
			/*
			if !node.is_direct {
				g.w_error('implicit bounds checks are not implemented, create one manually')
			}*/

			mut ptr := g.expr(node.left, ast.voidptr_type)
			if node.left_type == ast.string_type {
				ptr = g.deref(ptr, ast.voidptr_type)
			}

			size, _ := g.get_type_size_align(expected)
			index := g.expr(node.index, ast.int_type)

			// ptr + index * size
			new_ptr := binaryen.binary(g.mod, binaryen.addint32(), ptr, binaryen.binary(g.mod,
				binaryen.mulint32(), index, g.literalint(size, ast.int_type)))

			g.deref(new_ptr, expected)
		} */
		ast.StructInit {
			v := g.new_local('', node.typ)
			g.set_with_expr(node, v)
			g.get(v)
		}
		/* ast.SelectorExpr {
			g.cast_t(g.get_or_lea_lop(g.get_var_from_expr(node), node.typ), node.typ,
				expected)
		}
		ast.MatchExpr {
			g.w_error('wasm backend does not support match expressions yet')
		}
		ast.EnumVal {
			type_name := g.table.get_type_name(node.typ)
			ts_type := (g.table.sym(node.typ).info as ast.Enum).typ
			g.literalint(g.enum_vals[type_name].fields[node.val], ts_type)
		}
		ast.OffsetOf {
			styp := g.table.sym(node.struct_type)
			if styp.kind != .struct_ {
				g.v_error('__offsetof expects a struct Type as first argument', node.pos)
			}
			off := g.get_field_offset(node.struct_type, node.field)
			g.literalint(off, ast.u32_type)
		}
		ast.SizeOf {
			if !g.table.known_type_idx(node.typ) {
				g.v_error('unknown type `${*g.table.sym(node.typ)}`', node.pos)
			}
			size, _ := g.table.type_size(node.typ)
			g.literalint(size, ast.u32_type)
		}
		ast.BoolLiteral {
			val := if node.val { binaryen.literalint32(1) } else { binaryen.literalint32(0) }
			binaryen.constant(g.mod, val)
		}
		ast.StringLiteral {
			if g.table.sym(expected).info !is ast.Struct {
				offset, _ := g.allocate_string(node)
				return g.literalint(offset, ast.int_type)
			}

			pos := g.allocate_local_var('_anonstring', ast.string_type)

			expr := g.assign_expr_to_var(Var(Stack{ address: pos, ast_typ: ast.string_type }),
				node, ast.string_type)
			g.mknblock('EXPR(STRINGINIT)', [expr, g.lea_address(pos)])
		} */
		ast.InfixExpr {
			g.infix_expr(node, expected)
		}
		/* ast.PrefixExpr {
			g.prefix_expr(node)
		}
		ast.PostfixExpr {
			g.postfix_expr(node)
		} */
		ast.CharLiteral {
			rns := node.val.runes()[0]
			g.func.i32_const(rns)
		}
		ast.Ident {
			v := g.get_var_from_ident(node)
			g.get(v)
			g.cast(v.typ, expected)
		}
		ast.IntegerLiteral, ast.FloatLiteral {
			g.literal(node.val, expected)
		}
		ast.Nil {
			g.func.i32_const(0)
		}
		/* ast.IfExpr {
			g.if_expr(node)
		} */
		ast.CastExpr {
			g.expr(node.expr, node.expr_type)
			g.func.cast(g.as_numtype(g.get_wasm_type(node.expr_type)), node.expr_type.is_signed(), g.as_numtype(g.get_wasm_type(node.typ)))
		}
		ast.CallExpr {
			println(node)
			println(g.table.sym(expected))
			exit(1)
			mut name := node.name

			is_print := name in ['panic', 'println', 'print', 'eprintln', 'eprint']

			/* if name in wasm.wasm_builtins {
				panic("unimplemented")
				//return g.wasm_builtin(node.name, node)
			} */

			if node.is_method {
				name = '${g.table.get_type_name(node.receiver_type)}.${node.name}'
			}

			// callconv: {return structs} {method self} {arguments}
			
			// {return structs}
			//
			rts := g.unpack_type(node.return_type)
			for rt in rts {
				v := g.new_local('', rt)
			}

			// {method self}
			//
			if node.is_method {
				expr := if !node.left_type.is_ptr() && node.receiver_type.is_ptr() {
					ast.Expr(ast.PrefixExpr{
						op: .amp
						right: node.left
					})
				} else {
					node.left
				}
				g.expr(expr, node.receiver_type)
			}
			
			// {arguments}
			//
			for idx, arg in node.args {
				mut expr := arg.expr
				
				typ := arg.typ
				if is_print && typ != ast.string_type {
					has_str, _, _ := g.table.sym(typ).str_method_info()
					if typ != ast.string_type && !has_str {
						g.v_error('cannot implicitly convert as argument does not have a .str() function',
							arg.pos)
					}

					expr = ast.CallExpr{
						name: 'str'
						left: expr
						left_type: typ
						receiver_type: typ
						return_type: ast.string_type
						is_method: true
					}
				}

				g.expr(expr, node.expected_arg_types[idx])
			}
			g.func.call(name)
		}
		/* ast.CallExpr {
			mut name := node.name
			mut arguments := []binaryen.Expression{cap: node.args.len + 1}

			fret := g.function_return_wasm_type(node.return_type)
			is_print := name in ['panic', 'println', 'print', 'eprintln', 'eprint']

			if name in wasm.wasm_builtins {
				return g.wasm_builtin(node.name, node)
			}

			if node.is_method {
				name = '${g.table.get_type_name(node.receiver_type)}.${node.name}'
			}

			ret_types := g.unpack_type(node.return_type)
			structs := ret_types.filter(g.table.sym(it).info is ast.Struct && !it.is_real_pointer())
			mut structs_addrs := []int{cap: structs.len}

			// ABI: {return structs} {method `self`}, then {arguments}
			for typ in structs {
				pos := g.allocate_local_var('_anonstruct', typ)
				structs_addrs << pos
				arguments << g.lea_address(pos)
			}
			if node.is_method {
				expr := if !node.left_type.is_ptr() && node.receiver_type.is_ptr() {
					ast.Expr(ast.PrefixExpr{
						op: .amp
						right: node.left
					})
				} else {
					node.left
				}
				arguments << g.expr(expr, node.receiver_type)
			}
			for idx, arg in node.args {
				mut expr := arg.expr
				typ := arg.typ

				if is_print && typ != ast.string_type {
					has_str, _, _ := g.table.sym(typ).str_method_info()
					if typ != ast.string_type && !has_str {
						g.v_error('cannot implicitly convert as argument does not have a .str() function',
							arg.pos)
					}

					expr = ast.CallExpr{
						name: 'str'
						left: expr
						left_type: typ
						receiver_type: typ
						return_type: ast.string_type
						is_method: true
					}
				}
				arguments << g.expr(expr, node.expected_arg_types[idx])
			}

			mut call := binaryen.call(g.mod, name.str, arguments.data, arguments.len,
				fret)
			if structs.len != 0 {
				mut temporary := 0
				// The function's return values contains structs and must be reordered

				if ret_types.len - structs.len != 0 {
					temporary = g.new_local_temporary_anon_wtyp(fret)
					call = binaryen.localset(g.mod, temporary, call)
				}
				mut exprs := []binaryen.Expression{}

				mut sidx := 0
				mut tidx := 0
				for typ in ret_types {
					ts := g.table.sym(typ)

					if ts.info is ast.Struct {
						exprs << g.lea_address(structs_addrs[tidx])
						tidx++
					} else {
						exprs << binaryen.tupleextract(g.mod, binaryen.localget(g.mod,
							temporary, fret), sidx)
						sidx++
					}
				}

				vexpr := if exprs.len != 1 {
					binaryen.tuplemake(g.mod, exprs.data, exprs.len)
				} else {
					exprs[0]
				}

				call = g.mkblock([call, vexpr])
			}
			if expected == ast.void_type && node.return_type != ast.void_type {
				call = binaryen.drop(g.mod, call)
			}
			if node.is_noreturn {
				// `[noreturn]` functions cannot return values
				call = g.mkblock([call, binaryen.unreachable(g.mod)])
			}
			call
		} */
		else {
			g.w_error('wasm.expr(): unhandled node: ' + node.type_name())
		}
	}
}

fn (mut g Gen) expr_stmt(node ast.Stmt, expected ast.Type) {
	match node {
		/* ast.Block {
			g.expr_stmts(node.stmts, expected)
		} */
		ast.Return {
			mut r := 0
			for idx, expr in node.exprs {
				typ := g.ret_types[idx] // node.types LIES
				if g.is_param_type(typ) {
					g.set_with_expr(expr, g.return_vars[r])
					r++
				} else {
					g.expr(expr, typ)
				}
			}
			g.func.c_br(g.ret_br)
		}
		ast.ExprStmt {
			g.expr(node.expr, expected)
		}
		/* ast.ForStmt {
			lbl := g.new_for_label(node.label)

			lpp_name := 'L${lbl}'
			blk_name := 'B${lbl}'
			expr := if !node.is_inf {
				// binaryen.bif(g.mod, g.expr(node.cond, ast.bool_type))

				body := g.expr_stmts(node.stmts, ast.void_type)
				lbody := [
					// If !condition, leave.
					binaryen.br(g.mod, blk_name.str, binaryen.unary(g.mod, binaryen.eqzint32(),
						g.expr(node.cond, ast.bool_type)), unsafe { nil }),
					// Body.
					body,
					// Unconditional loop back to top.
					binaryen.br(g.mod, lpp_name.str, unsafe { nil }, unsafe { nil }),
				]
				loop := binaryen.loop(g.mod, lpp_name.str, g.mkblock(lbody))

				binaryen.block(g.mod, blk_name.str, &loop, 1, type_none)
			} else {
				loop_top := binaryen.br(g.mod, lpp_name.str, unsafe { nil }, unsafe { nil })

				loop := binaryen.loop(g.mod, lpp_name.str, g.mkblock([
					g.expr_stmts(node.stmts, ast.void_type),
					loop_top,
				]))

				binaryen.block(g.mod, blk_name.str, &loop, 1, type_none)
			}
			g.pop_for_label()
			expr
		}
		ast.ForCStmt {
			mut for_stmt := []binaryen.Expression{}
			if node.has_init {
				for_stmt << g.expr_stmt(node.init, ast.void_type)
			}

			lbl := g.new_for_label(node.label)
			lpp_name := 'L${lbl}'
			blk_name := 'B${lbl}'

			mut loop_exprs := []binaryen.Expression{}
			if node.has_cond {
				condexpr := binaryen.unary(g.mod, binaryen.eqzint32(), g.expr(node.cond,
					ast.bool_type))
				loop_exprs << binaryen.br(g.mod, blk_name.str, condexpr, unsafe { nil })
			}
			loop_exprs << g.expr_stmts(node.stmts, ast.void_type)

			if node.has_inc {
				loop_exprs << g.expr_stmt(node.inc, ast.void_type)
			}
			loop_exprs << binaryen.br(g.mod, lpp_name.str, unsafe { nil }, unsafe { nil })
			loop := binaryen.loop(g.mod, lpp_name.str, g.mkblock(loop_exprs))

			for_stmt << binaryen.block(g.mod, blk_name.str, &loop, 1, type_none)
			g.pop_for_label()
			g.mkblock(for_stmt)
		}
		ast.BranchStmt {
			mut blabel := if node.label != '' {
				node.label
			} else {
				g.for_labels[g.for_labels.len - 1]
			}

			if node.kind == .key_break {
				blabel = 'B${blabel}'
			} else {
				blabel = 'L${blabel}'
			}
			binaryen.br(g.mod, blabel.str, unsafe { nil }, unsafe { nil })
		} */
		ast.AssignStmt {
			if (node.left.len > 1 && node.right.len == 1) || node.has_cross_var {
				// `a, b := foo()`
				// `a, b := if cond { 1, 2 } else { 3, 4 }`
				// `a, b = b, a`

				// g.multi_assign_stmt(node)
				panic("unimplemented")
			} else {
				// `a := 1` | `a, b := 1, 2`

				for i, left in node.left {
					right := node.right[i]
					typ := node.left_types[i]

					// `_ = expr` must be evaluated even if the value is being dropped!
					// The optimiser would remove expressions without side effects.

					// a    =  expr
					// b    *= expr
					// _    =  expr
					// a.b  =  expr
					// *a   =  expr
					// a[b] =  expr

					if left is ast.Ident {
						// `_ = expr`
						if left.kind == .blank_ident {
							// expression still may have side effect
							g.expr(right, typ)
							g.func.drop()
							continue
						}
						if node.op == .decl_assign {
							g.new_local(left.name, typ)
						}
					}

					if v := g.get_var_from_expr(left) {
						g.set_with_expr(right, v)
					} else {
						panic("unimplemented")
					}
				}
			}
		}
		else {
			g.w_error('wasm.expr_stmt(): unhandled node: ' + node.type_name())
		}
	}
}

pub fn (mut g Gen) expr_stmts(stmts []ast.Stmt, expected ast.Type) {
	for idx, stmt in stmts {
		rtyp := if idx + 1 == stmts.len {
			expected
		} else {
			ast.void_type
		}
		g.expr_stmt(stmt, rtyp)
	}
}

fn (mut g Gen) toplevel_stmt(node ast.Stmt) {
	match node {
		ast.FnDecl {
			g.fn_decl(node)
		}
		ast.Module {
			if ns := node.attrs.find_first('wasm_import_namespace') {
				g.module_import_namespace = ns.arg
			} else {
				g.module_import_namespace = 'env'
			}
		}
		ast.GlobalDecl {}
		ast.ConstDecl {}
		ast.Import {}
		ast.StructDecl {}
		ast.EnumDecl {}
		ast.TypeDecl {}
		else {
			g.w_error('wasm.toplevel_stmt(): unhandled node: ' + node.type_name())
		}
	}
}

pub fn (mut g Gen) toplevel_stmts(stmts []ast.Stmt) {
	for stmt in stmts {
		g.toplevel_stmt(stmt)
	}
}

struct Enum {
mut:
	fields map[string]i64
}

pub fn (mut g Gen) calculate_enum_fields() {
	// `enum Enum as u64` is supported
	for name, decl in g.table.enum_decls {
		mut enum_vals := Enum{}
		mut value := if decl.is_flag { i64(1) } else { 0 }
		for field in decl.fields {
			if field.has_expr {
				value = g.eval.expr(field.expr, decl.typ).int_val()
			}
			enum_vals.fields[field.name] = value
			if decl.is_flag {
				value <<= 1
			} else {
				value++
			}
		}
		g.enum_vals[name] = enum_vals
	}
}

pub fn gen(files []&ast.File, table &ast.Table, out_name string, w_pref &pref.Preferences) {
	mut g := &Gen{
		table: table
		pref: w_pref
		files: files
		eval: eval.new_eval(table, w_pref)
	}
	g.table.pointer_size = 4
	g.mod.assign_memory("memory", true, 1, none)

	if g.pref.os == .browser {
		eprintln('`-os browser` is experimental and will not live up to expectations...')
	}

	g.calculate_enum_fields()
	for file in g.files {
		g.file_path = file.path
		if g.pref.is_debug {
			// g.file_path_idx = binaryen.moduleadddebuginfofilename(g.mod, g.file_path.str)
		}
		if file.errors.len > 0 {
			util.verror('wasm error', file.errors[0].str())
		}
		g.toplevel_stmts(file.stmts)
	}
	//g.housekeeping()

	/* mut valid := binaryen.modulevalidate(g.mod)
	if valid {
		binaryen.setdebuginfo(w_pref.is_debug)
		if w_pref.is_prod {
			eprintln('`-prod` is not implemented')
		}
	} */

	mod := g.mod.compile()

	if out_name == '-' {
		eprintln('pretty printing is not implemented')
		print(mod.bytestr())
		/* if g.pref.is_verbose {
			binaryen.moduleprint(g.mod)
		} else {
			binaryen.moduleprintstackir(g.mod, w_pref.is_prod)
		} */
	}

	/* if !valid {
		g.w_error('validation failed, this should not happen. report an issue with the above messages')
	} */

	if out_name != '-' {
		os.write_file_array(out_name, mod) or { panic(err) }
	}
}
