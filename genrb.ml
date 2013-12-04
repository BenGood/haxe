(*
 * Copyright (C)2005-2013 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 *)

open Type
open Common

type context_infos = {
	com : Common.context;
}

type context = {
	inf : context_infos;
	ch : out_channel;
	buf : Buffer.t;
	path : path;
	mutable get_sets : (string * bool,string) Hashtbl.t;
	mutable curclass : tclass;
	mutable tabs : string;
	mutable in_value : tvar option;
	mutable in_static : bool;
	mutable handle_break : bool;
	mutable imports : (string,string list list) Hashtbl.t;
	mutable gen_uid : int;
	mutable local_types : t list;
	mutable constructor_block : bool;
	mutable block_inits : (unit -> unit) option;
        mutable in_expression : bool;
        mutable in_block_consumer : bool;
        mutable protected_mode : bool;
        mutable newlined : bool;
        mutable dirty_line : bool;
        mutable field_names : (string,bool) Hashtbl.t;
        mutable has_statics : bool;
}

let is_var_field f =
	match f with
	| FStatic (_,f) | FInstance (_,f) ->
		(match f.cf_kind with Var _ -> true | _ -> false)
	| _ ->
		false

let is_special_compare e1 e2 =
	match e1.eexpr, e2.eexpr with
	| TConst TNull, _  | _ , TConst TNull -> None
	| _ ->
	match follow e1.etype, follow e2.etype with
	| TInst ({ cl_path = [],"Xml" } as c,_) , _ | _ , TInst ({ cl_path = [],"Xml" } as c,_) -> Some c
	| _ -> None

let tweak_class_name n =
  (String.capitalize n)

let tweak_package_name n =
  (String.capitalize n)

let camel_to_underscore n = 
  let r = Str.regexp "\\([a-z]\\)\\([A-Z]\\)" in
  String.lowercase (Str.global_replace r "\\1_\\2" n)

let tweak_s_type_path (p,s) = match p with [] -> s | _ -> "::" ^ String.concat "::" (List.map tweak_package_name p) ^ "::" ^ s

let req_path (p,s) = match p with [] -> camel_to_underscore(s) | _ -> String.concat "/" (List.map camel_to_underscore p) ^ "/" ^ camel_to_underscore(s)


let protect name =
	match name with
	| "Error" | "Namespace" -> "_" ^ name
	| _ -> name

let s_path ctx stat path p =
	match path with
	| ([],name) ->
		(match name with
		| "Int" -> "int"
		| "Float" -> "Number"
		| "Dynamic" -> "Object"
		| "Bool" -> "Boolean"
		| "Enum" -> "Class"
		| "EnumValue" -> "enum"
		| _ -> name)
	| (["flash"],"FlashXml__") ->
		"Xml"
	| (["flash";"errors"],"Error") ->
		"Error"
	| (["flash"],"Vector") ->
		"Vector"
	| (["flash";"xml"],"XML") ->
		"XML"
	| (["flash";"xml"],"XMLList") ->
		"XMLList"
	| ["flash";"utils"],"QName" ->
		"QName"
	| ["flash";"utils"],"Namespace" ->
		"Namespace"
	| (["haxe"],"Int32") when not stat ->
		"int"
	| (pack,name) ->
		let name = protect name in
		let packs = (try Hashtbl.find ctx.imports name with Not_found -> []) in
		if not (List.mem pack packs) then Hashtbl.replace ctx.imports name (pack :: packs);
		tweak_s_type_path (pack,name)

let reserved =
	let h = Hashtbl.create 0 in
	List.iter (fun l -> Hashtbl.add h l ())
	(* these ones are defined in order to prevent recursion in some Std functions *)
	["is";"as";"int";"uint";"const";"getTimer";"typeof";"parseInt";"parseFloat";
	(* AS3 keywords which are not Haxe ones *)
	"finally";"with";"final";"internal";"native";"namespace";"include";"delete";
	(* some globals give some errors with Flex SDK as well *)
	"print";"trace";
	(* we don't include get+set since they are not 'real' keywords, but they can't be used as method names *)
	"function";"class";"var";"if";"else";"while";"do";"for";"break";"next";"return";"extends";"implements";
	"import";"switch";"case";"default";"static";"public";"private";"try";"catch";"new";"this";"throw";"interface";
	"override";"package";"nil";"true";"false";"void";
	 "begin";"rescue";"end";
	];
	h

	(* "each", "label" : removed (actually allowed in locals and fields accesses) *)

let s_ident m =
  let n = camel_to_underscore m in
  let ch = (String.get n 0) in
  if ch >= 'A' && ch <= 'Z' then
    "_" ^ n
  else if n = "to_string" then
    "to_s"
  else
    if Hashtbl.mem reserved n then "_" ^ n else n

let s_ident_local ctx m =
  (* not quite sure if collision is an issue; ruby local vars may be 
     indistinguishable from a setter in certain cases, need to think
     about this *)
  (* if Hashtbl.mem ctx.field_names m then
    s_ident "__" ^ m
  else *)
    s_ident m

let rec is_string_type t =
	match follow t with
	| TInst ({cl_path = ([], "String")}, _) -> true
	| TAnon a ->
	   (match !(a.a_status) with
	   | Statics ({cl_path = ([], "String")}) -> true
	   | _ -> false)
	| TAbstract (a,pl) -> is_string_type (Codegen.Abstract.get_underlying_type a pl)
	| _ -> false

let is_string_expr e = is_string_type e.etype

let rec create_dir acc = function
	| [] -> ()
	| d :: l ->
		let dir = String.concat "/" (List.rev (d :: acc)) in
		if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
		create_dir (d :: acc) l

let init infos path =
	let dir = infos.com.file :: fst path in
	create_dir [] dir;
	let ch = open_out (String.concat "/" dir ^ "/" ^ (camel_to_underscore (snd path)) ^ ".rb") in
	let imports = Hashtbl.create 0 in
	Hashtbl.add imports (snd path) [fst path];
	{
		inf = infos;
		tabs = "";
		ch = ch;
		path = path;
		buf = Buffer.create (1 lsl 14);
		in_value = None;
		in_static = false;
		handle_break = false;
		imports = imports;
		curclass = null_class;
		gen_uid = 0;
		local_types = [];
		get_sets = Hashtbl.create 0;
		constructor_block = false;
		block_inits = None;
	        in_expression = false;
	        in_block_consumer = false;
	        protected_mode = false;
	        newlined = true;
	        dirty_line = false;
	        field_names = Hashtbl.create 0;
	        has_statics = false;
	}

let close ctx =
  let module_name = (String.concat "::" (List.map tweak_package_name (fst ctx.path))) in
  output_string ctx.ch (Printf.sprintf "%s %s\n" (if module_name <> "" then "module" else "begin") module_name);
	output_string ctx.ch (Buffer.contents ctx.buf);
	close_out ctx.ch

let gen_local ctx l =
	ctx.gen_uid <- ctx.gen_uid + 1;
	if ctx.gen_uid = 1 then l else l ^ string_of_int ctx.gen_uid

let spr ctx s = 
  ctx.newlined <- false;
  ctx.dirty_line <- true;
  Buffer.add_string ctx.buf s
  
let print ctx = 
  ctx.newlined <- false;
  ctx.dirty_line <- true;
  Printf.kprintf (fun s -> Buffer.add_string ctx.buf s)

let unsupported p = error "This expression cannot be generated to Ruby" p

let newline ctx =
  if not ctx.newlined then
    ctx.newlined <- not ctx.dirty_line;
  let nl = ctx.newlined in
  let rec loop p =
    match Buffer.nth ctx.buf p with
    | '}' | '{' | ':' | ';' -> print ctx "\n%s" ctx.tabs
    | '\n' | '\t' -> loop (p - 1)
    | _ -> print ctx "\n%s" ctx.tabs
  in
  loop (Buffer.length ctx.buf - 1);
  ctx.newlined <- nl;
  ctx.dirty_line <- false
      
let soft_newline ctx = 
  if not ctx.newlined then newline ctx
      
let block_newline ctx = match Buffer.nth ctx.buf (Buffer.length ctx.buf - 1) with
	| '}' -> print ctx "\n%s" ctx.tabs
	| _ -> newline ctx

let force_block e =
  match e.eexpr with
  | TBlock _ -> e
  | _ ->
      mk (TBlock [e]) e.etype e.epos
      
let rec concat ctx s f = function
	| [] -> ()
	| [x] -> f x
	| x :: l ->
		f x;
		spr ctx s;
		concat ctx s f l

let open_block ctx =
	let oldt = ctx.tabs in
	ctx.tabs <- "  " ^ ctx.tabs;
	(fun() -> ctx.tabs <- oldt)


let parent e =
	match e.eexpr with
	| TParenthesis _ -> e
	| _ -> mk (TParenthesis e) e.etype e.epos

let deparent e =
	match e.eexpr with
	| TParenthesis e2 -> e2
	| _ -> e

let default_value tstr =
	match tstr with
	| "int" | "uint" -> "0"
	| "Number" -> "NaN"
	| "Boolean" -> "false"
	| _ -> "nil"

let rec type_str ctx t p =
	match t with
	| TEnum _ | TInst _ when List.memq t ctx.local_types ->
		"*"
	| TAbstract ({ a_impl = Some _ } as a,pl) ->
		type_str ctx (apply_params a.a_types pl a.a_this) p
	| TAbstract (a,_) ->
		(match a.a_path with
		| [], "Void" -> "void"
		| [], "UInt" -> "uint"
		| [], "Int" -> "int"
		| [], "Float" -> "Number"
		| [], "Bool" -> "Boolean"
		| _ -> s_path ctx true a.a_path p)
	| TEnum (e,_) ->
		if e.e_extern then (match e.e_path with
			| [], "Void" -> "void"
			| [], "Bool" -> "Boolean"
			| _ ->
				let rec loop = function
					| [] -> "Object"
					| (Ast.Meta.FakeEnum,[Ast.EConst (Ast.Ident n),_],_) :: _ ->
						(match n with
						| "Int" -> "int"
						| "UInt" -> "uint"
						| _ -> n)
					| _ :: l -> loop l
				in
				loop e.e_meta
		) else
			s_path ctx true e.e_path p
	| TInst ({ cl_path = ["flash"],"Vector" },[pt]) ->
		(match pt with
		| TInst({cl_kind = KTypeParameter _},_) -> "*"
		| _ -> "Vector.<" ^ type_str ctx pt p ^ ">")
	| TInst (c,_) ->
		(match c.cl_kind with
		| KNormal | KGeneric | KGenericInstance _ | KAbstractImpl _ -> s_path ctx false c.cl_path p
		| KTypeParameter _ | KExtension _ | KExpr _ | KMacroType -> "*")
	| TFun _ ->
		"Function"
	| TMono r ->
		(match !r with None -> "*" | Some t -> type_str ctx t p)
	| TAnon _ | TDynamic _ ->
		"*"
	| TType (t,args) ->
		(match t.t_path with
		| [], "UInt" -> "uint"
		| [] , "Null" ->
			(match args with
			| [t] ->
				(match follow t with
				| TAbstract ({ a_path = [],"UInt" },_)
				| TAbstract ({ a_path = [],"Int" },_)
				| TAbstract ({ a_path = [],"Float" },_)
				| TAbstract ({ a_path = [],"Bool" },_)
				| TInst ({ cl_path = [],"Int" },_)
				| TInst ({ cl_path = [],"Float" },_)
				| TEnum ({ e_path = [],"Bool" },_) -> "*"
				| _ -> type_str ctx t p)
			| _ -> assert false);
		| _ -> type_str ctx (apply_params t.t_types args t.t_type) p)
	| TLazy f ->
		type_str ctx ((!f)()) p

let rec iter_switch_break in_switch e =
	match e.eexpr with
	| TFunction _ | TWhile _ | TFor _ -> ()
	| TSwitch _ | TPatMatch _ when not in_switch -> iter_switch_break true e
	| TBreak when in_switch -> raise Exit
	| _ -> iter (iter_switch_break in_switch) e

let handle_break ctx e =
	let old_handle = ctx.handle_break in
	try
		iter_switch_break false e;
		ctx.handle_break <- false;
		(fun() -> ctx.handle_break <- old_handle)
	with
		Exit ->
			spr ctx "try {";
			let b = open_block ctx in
			newline ctx;
			ctx.handle_break <- true;
			(fun() ->
				b();
				ctx.handle_break <- old_handle;
				newline ctx;
				spr ctx "} catch( e : * ) { if( e != \"__break__\" ) throw e; }";
			)

let this ctx = if ctx.in_value <> None then "_this_" else "self"

let has_feature ctx = Common.has_feature ctx.inf.com
let add_feature ctx = Common.add_feature ctx.inf.com

let is_dynamic_iterator ctx e =
	let check x =
		has_feature ctx "HxOverrides.iter" && (match follow x.etype with TInst ({ cl_path = [],"Array" },_) | TAnon _ | TDynamic _ | TMono _ -> true | _ -> false)
	in
	match e.eexpr with
	| TField (x,f) when field_name f = "iterator" -> check x
	| _ ->
		false

let generate_resources infos =
	if Hashtbl.length infos.com.resources <> 0 then begin
		let dir = (infos.com.file :: ["__res"]) in
		create_dir [] dir;
		let add_resource name data =
			let ch = open_out_bin (String.concat "/" (dir @ [name])) in
			output_string ch data;
			close_out ch
		in
		Hashtbl.iter (fun name data -> add_resource name data) infos.com.resources;
		let ctx = init infos ([],"__resources__") in
		spr ctx "  import flash.utils.Dictionary;\n";
		spr ctx "  public class __resources__ {\n";
		spr ctx "    public static var list:Dictionary;\n";
		let inits = ref [] in
		let k = ref 0 in
		Hashtbl.iter (fun name _ ->
			let varname = ("v" ^ (string_of_int !k)) in
			k := !k + 1;
			print ctx "    [Embed(source = \"__res/%s\", mimeType = \"application/octet-stream\")]\n" name;
			print ctx "    public static var %s:Class;\n" varname;
			inits := ("list[\"" ^name^ "\"] = " ^ varname ^ ";") :: !inits;
		) infos.com.resources;
		spr ctx "    static public function __init__():void {\n";
		spr ctx "      list = new Dictionary();\n";
		List.iter (fun init ->
			print ctx "      %s\n" init
		) !inits;
		spr ctx "    }\n";
		spr ctx "  }\n";
		spr ctx "}";
		close ctx;
	end

let gen_constant ctx p = function
	| TInt i -> print ctx "%ld" i
	| TFloat s -> spr ctx s
	| TString s -> print ctx "\"%s\"" (Ast.s_escape s)
	| TBool b -> spr ctx (if b then "true" else "false")
	| TNull -> spr ctx "nil"
	| TThis -> spr ctx (this ctx)
	| TSuper -> spr ctx "super"

let gen_function_header ctx name f params p in_expression =
	let old = ctx.in_value in
	let old_t = ctx.local_types in
	let old_bi = ctx.block_inits in
	let old_ie = ctx.in_expression in
	let old_ibc = ctx.in_block_consumer in
	ctx.in_value <- None;
	ctx.in_expression <- in_expression;
	ctx.local_types <- List.map snd params @ ctx.local_types;
	let init () =
 		List.iter (fun (v,o) -> match o with
			| Some c when is_nullable v.v_type && c <> TNull ->
				newline ctx;
				print ctx "if(%s==nil) %s=" v.v_name v.v_name;
				gen_constant ctx p c;
			| _ -> ()
		) f.tf_args;
		ctx.block_inits <- None;
	in
	ctx.block_inits <- Some init;
	let str_def = (if in_expression then (if ctx.in_block_consumer then "" else "lambda") else "def") in
	let str_pre = (if in_expression then "{|" else "(") in
	let str_pre0 = (if in_expression then "{" else " ") in
	let str_post = (if in_expression then "|" else ")") in
	if not in_expression then begin
	  soft_newline ctx;
	  soft_newline ctx;
	end;
	if ctx.constructor_block then
	  print ctx "def initialize%s" (if (List.length f.tf_args)>0 then "(" else "")
	else
	  print ctx "%s%s%s%s" str_def (if ctx.in_static && not(in_expression) then (" " ^ (tweak_class_name (snd ctx.curclass.cl_path)) ^ ".") else " ") (match name with None -> "" | Some (n,meta) ->
	    let rec loop = function
	      | [] -> n
	      | (Ast.Meta.Getter,[Ast.EConst (Ast.Ident i),_],_) :: _ -> "get " ^ i
	      | (Ast.Meta.Setter,[Ast.EConst (Ast.Ident i),_],_) :: _ -> "set " ^ i
	      | _ :: l -> loop l
	    in
	    "" ^ loop meta) (if (List.length f.tf_args)>0 then str_pre else str_pre0);
	ctx.constructor_block <- false;
	concat ctx "," (fun (v,c) ->
		let tstr = type_str ctx v.v_type p in
		print ctx "%s" (s_ident_local ctx v.v_name);
		match c with
		| None ->
			if ctx.constructor_block then print ctx " = %s" (default_value tstr);
		| Some c ->
			spr ctx " = ";
			gen_constant ctx p c
	) f.tf_args;
        if (List.length f.tf_args)>0 then print ctx "%s" str_post;
	(fun () ->
		ctx.in_value <- old;
		ctx.local_types <- old_t;
		ctx.block_inits <- old_bi;
	        ctx.in_expression <- old_ie;
	        ctx.in_block_consumer <- old_ibc;
	)
	  
let rec gen_call ctx e el r =
	match e.eexpr , el with
	| TCall (x,_) , el ->
		spr ctx "(";
		gen_value ctx e;
		spr ctx ")";
	        show_args ctx el;
	| TLocal { v_name = "__is__" } , [e1;e2] ->
		gen_value ctx e1;
		spr ctx " is ";
		gen_value ctx e2;
	| TLocal { v_name = "__in__" } , [e1;e2] ->
		gen_value ctx e1;
		spr ctx " in ";
		gen_value ctx e2;
	| TLocal { v_name = "__pow__" }, [e1;e2] ->
		gen_value ctx e1;
		spr ctx " ** ";
		gen_value ctx e2;
	| TLocal { v_name = "__int__" }, [e] ->
		spr ctx "int(";
		gen_value ctx e;
		spr ctx ")";
	| TLocal { v_name = "__float__" }, [e] ->
		spr ctx "Number(";
		gen_value ctx e;
		spr ctx ")";
	| TLocal { v_name = "__typeof__" }, [e] ->
		spr ctx "typeof ";
		gen_value ctx e;
	| TLocal { v_name = "__dotcall__" }, eo :: { eexpr = TConst (TString code) } :: el ->
	    gen_value ctx eo;	
	    spr ctx ".";
	    spr ctx code;
	    show_args ctx el;
	| TLocal { v_name = "__pass_block__" }, [e0;e1;{ eexpr = TFunction _ } as e2] ->
		gen_value ctx e0;
		spr ctx ".";
		gen_value ctx e1;
	        ctx.in_block_consumer <- true;
		gen_value ctx e2;
	        ctx.in_block_consumer <- false;
	| TLocal { v_name = "__pass_block__" }, [e0;e1;e2] ->
		gen_value ctx e0;
		spr ctx ".";
		gen_value ctx e1;
		spr ctx "{|a,b| (";
		gen_value ctx e2;
		spr ctx ").call(a,b)}";
	| TLocal { v_name = "__js__" }, [{ eexpr = TConst (TString code) }] ->
		spr ctx (String.concat "\n" (ExtString.String.nsplit code "\r\n"))
	| TLocal { v_name = "__keys__" }, [e] ->
		let ret = (match ctx.in_value with None -> assert false | Some r -> r) in
		print ctx "%s = new Array()" ret.v_name;
		newline ctx;
		let tmp = gen_local ctx "$k" in
		print ctx "for(var %s : String in " tmp;
		gen_value ctx e;
		print ctx ") %s.push(%s)" ret.v_name tmp;
	| TLocal { v_name = "__hkeys__" }, [e] ->
		let ret = (match ctx.in_value with None -> assert false | Some r -> r) in
		print ctx "%s = new Array()" ret.v_name;
		newline ctx;
		let tmp = gen_local ctx "$k" in
		print ctx "for(var %s : String in " tmp;
		gen_value ctx e;
		print ctx ") %s.push(%s.substr(1))" ret.v_name tmp;
	| TLocal { v_name = "__foreach__" }, [e] ->
		let ret = (match ctx.in_value with None -> assert false | Some r -> r) in
		print ctx "%s = new Array()" ret.v_name;
		newline ctx;
		let tmp = gen_local ctx "$k" in
		print ctx "for each(var %s : * in " tmp;
		gen_value ctx e;
		print ctx ") %s.push(%s)" ret.v_name tmp;
	| TLocal { v_name = "__new__" }, e :: args ->
		spr ctx "new ";
		gen_value ctx e;
	        show_args ctx args;
	| TLocal { v_name = "__delete__" }, [e;f] ->
		spr ctx "delete(";
		gen_value ctx e;
		spr ctx "[";
		gen_value ctx f;
		spr ctx "]";
		spr ctx ")";
	| TLocal { v_name = "__set__" }, [e;k;v] ->
		gen_value ctx e;
		spr ctx "[";
		gen_value ctx k;
		spr ctx "] = ";
		gen_value ctx v;
	| TLocal { v_name = "__get__" }, [e;k] ->
		gen_value ctx e;
		spr ctx "[";
		gen_value ctx k;
		spr ctx "]";
	| TLocal { v_name = "__get2__" }, [e;k1;k2] ->
	    gen_value ctx e;
	    spr ctx "[";
	    gen_value ctx k1;
	    spr ctx "..";
	    (match k2.eexpr with
	    | TConst TNull ->
		spr ctx "-1";
	    | _ ->
		gen_value ctx k2);
	    spr ctx "]";
	| TLocal { v_name = "__unprotect__" }, [e] ->
		gen_value ctx e
	| TLocal { v_name = "__vector__" }, [e] ->
		spr ctx (type_str ctx r e.epos);
		spr ctx "(";
		gen_value ctx e;
		spr ctx ")"
	| TLocal x, el when (match x.v_type with TFun _ -> true | TAnon _ -> true | _ -> false) ->
		spr ctx "(";
		gen_value ctx e;
		spr ctx ").call";
	        show_args ctx el;
	| TField (_, FStatic( { cl_path = (["flash"],"Lib") }, { cf_name = "as" })), [e1;e2] ->
		gen_value ctx e1;
		spr ctx " as ";
		gen_value ctx e2
	| TField (_, FStatic ({ cl_path = (["flash"],"Vector") }, cf)), args ->
		(match cf.cf_name, args with
		| "ofArray", [e] | "convert", [e] ->
			(match follow r with
			| TInst ({ cl_path = (["flash"],"Vector") },[t]) ->
				print ctx "Vector.<%s>(" (type_str ctx t e.epos);
				gen_value ctx e;
				print ctx ")";
			| _ -> assert false)
		| _ -> assert false)
	| TField (ee,f), args when is_var_field f ->
		spr ctx "(";
		gen_value ctx e;
		spr ctx ")";
		spr ctx ".call";
	        show_args ctx el;
	| _ ->
		gen_value ctx e;
	        show_args ctx el;

and show_args ctx el =
  if (List.length el)>0 then spr ctx "(";
  concat ctx "," (gen_value ctx) el;
  if (List.length el)>0 then spr ctx ")"

and gen_value_op ctx e =
	match e.eexpr with
	| TBinop (op,_,_) when op = Ast.OpAnd || op = Ast.OpOr || op = Ast.OpXor ->
		spr ctx "(";
		gen_value ctx e;
		spr ctx ")";
	| _ ->
		gen_value ctx e

and gen_field_access ctx t s =
	let field c =
		match fst c.cl_path, snd c.cl_path, s with
		| [], "Math", "NaN"
		| [], "Math", "NEGATIVE_INFINITY"
		| [], "Math", "POSITIVE_INFINITY"
		| [], "Math", "isFinite"
		| [], "Math", "isNaN"
		| [], "Date", "now"
		| [], "Date", "fromTime"
		| [], "Date", "fromString"
		->
			print ctx "[\"%s\"]" s
		| [], "String", "charCodeAt" ->
			spr ctx "[\"charCodeAtHX\"]"
		| [], "Array", "map" ->
			spr ctx "[\"mapHX\"]"
		| [], "Array", "filter" ->
			spr ctx "[\"filterHX\"]"
		| [], "Date", "toString" ->
			print ctx "[\"toStringHX\"]"
		| [], "String", "cca" ->
			print ctx ".charCodeAt"
		| ["flash";"xml"], "XML", "namespace" ->
			print ctx ".namespace"
		| _ ->
			print ctx ".%s" (s_ident s)
	in
	match follow t with
	| TInst (c,_) -> field c
	| TAnon a ->
		(match !(a.a_status) with
		| Statics c -> field c
		| _ -> print ctx ".%s" (s_ident s))
	| _ ->
		print ctx ".%s" (s_ident s)

and gen_expr ?(preblocked=false) ?(postblocked=false) ?(shortenable=true) ctx e =
	match e.eexpr with
	| TConst c ->
		gen_constant ctx e.epos c
	| TLocal v ->
		spr ctx (s_ident_local ctx v.v_name)
	| TArray ({ eexpr = TLocal { v_name = "__global__" } },{ eexpr = TConst (TString s) }) ->
		let path = Ast.parse_path s in
		spr ctx (s_path ctx false path e.epos)
	| TArray (e1,e2) ->
		gen_value ctx e1;
		spr ctx "[";
		gen_value ctx e2;
		spr ctx "]";
	| TBinop (Ast.OpEq,e1,e2) when (match is_special_compare e1 e2 with Some c -> true | None -> false) ->
		let c = match is_special_compare e1 e2 with Some c -> c | None -> assert false in
		gen_expr ctx (mk (TCall (mk (TField (mk (TTypeExpr (TClassDecl c)) t_dynamic e.epos,FDynamic "compare")) t_dynamic e.epos,[e1;e2])) ctx.inf.com.basic.tbool e.epos);
	| TBinop (Ast.OpAdd,e1,e2) when (is_string_expr e1 || is_string_expr e2) ->
	    gen_value_op ctx e1;
	    if not(is_string_expr e1) then spr ctx ".to_s";
	    spr ctx " + ";
	    gen_value_op ctx e2;
	    if not(is_string_expr e2) then spr ctx ".to_s";
	(* what is this used for? *)
(* 	| TBinop (op,{ eexpr = TField (e1,s) },e2) ->
		gen_value_op ctx e1;
		gen_field_access ctx e1.etype s;
		print ctx " %s " (Ast.s_binop op);
		gen_value_op ctx e2; *)
	| TField (x,f) when field_name f = "iterator" && is_dynamic_iterator ctx e ->
	    add_feature ctx "use.$iterator";
	    print ctx "_hx_iterator(";
	    gen_value ctx x;
	    print ctx ").call";
	| TBinop (op,e1,e2) ->
		gen_value_op ctx e1;
		print ctx " %s " (Ast.s_binop op);
		gen_value_op ctx e2;
	(* variable fields on interfaces are generated as (class["field"] as class) *)
	| TField ({etype = TInst({cl_interface = true} as c,_)} as e,FInstance (_,{ cf_name = s }))
		when (try (match (PMap.find s c.cl_fields).cf_kind with Var _ -> true | _ -> false) with Not_found -> false) ->
		spr ctx "(";
		gen_value ctx e;
		print ctx "[\"%s\"]" s;
		print ctx " as %s)" (type_str ctx e.etype e.epos);
	| TField({eexpr = TArrayDecl _} as e1,s) ->
		spr ctx "(";
		gen_expr ctx e1;
		spr ctx ")";
		gen_field_access ctx e1.etype (field_name s)
	| TEnumParameter (e,_,i) ->
		gen_value ctx e;
		print ctx ".params[%i]" i;
	| TField ({ eexpr = TConst (TThis) },s) when is_var_field s ->
	    spr ctx "@";
	    spr ctx (field_name s)
	| TField (e,s) ->
   		gen_value ctx e;
		gen_field_access ctx e.etype (field_name s)
	| TTypeExpr t ->
		spr ctx (s_path ctx true (t_path t) e.epos)
	| TParenthesis e ->
		spr ctx "(";
		gen_value ctx e;
		spr ctx ")";
	| TMeta (_,e) ->
		gen_expr ctx e
	| TReturn eo ->
		if ctx.in_value <> None then unsupported e.epos;
		(match eo with
		| None ->
			spr ctx "return"
		| Some e when (match follow e.etype with TEnum({ e_path = [],"Void" },[]) | TAbstract ({ a_path = [],"Void" },[]) -> true | _ -> false) ->
			print ctx "{";
			let bend = open_block ctx in
			newline ctx;
			gen_value ctx e;
			newline ctx;
			spr ctx "return";
			bend();
			newline ctx;
			print ctx "}";
		| Some e ->
			spr ctx "return ";
			gen_value ctx e);
	| TBreak ->
		if ctx.in_value <> None then unsupported e.epos;
		if ctx.handle_break then spr ctx "throw \"__break__\"" else spr ctx "break"
	| TContinue ->
		if ctx.in_value <> None then unsupported e.epos;
		spr ctx "next"
	| TBlock el ->
	        if not preblocked then print ctx "begin";
		let bend = open_block ctx in
		(match ctx.block_inits with None -> () | Some i -> i());
		List.iter (fun e -> block_newline ctx; gen_expr ctx e) el;
		bend();
		if not postblocked then begin
		  newline ctx;
		  print ctx "%s" (if ctx.in_expression then "}" else "end");
		end;
	| TFunction f ->
		let h = gen_function_header ctx None f [] e.epos true in
		let old = ctx.in_static in
		let old_bc = ctx.in_block_consumer in
		ctx.in_static <- true;
	        ctx.in_block_consumer <- false;
		gen_expr ~preblocked:true ctx f.tf_expr;
		ctx.in_block_consumer <- old_bc;
		ctx.in_static <- old;
		h();
	| TCall (v,el) ->
		gen_call ctx v el e.etype
	| TArrayDecl el ->
		spr ctx "[";
		concat ctx "," (gen_value ctx) el;
		spr ctx "]"
	| TThrow e ->
		spr ctx "throw ";
		gen_value ctx e;
	| TVars [] ->
		()
	| TVars vl ->
		(* spr ctx "var "; *)
		concat ctx ", " (fun (v,eo) ->
			print ctx "%s" (s_ident_local ctx v.v_name) (*type_str ctx v.v_type e.epos*);
			match eo with
			| None -> 
			    spr ctx " = nil";
			| Some e ->
			    spr ctx " = ";
			    match e.eexpr with
			    | TUnop (op,Ast.Postfix,e2) when op = Ast.Increment ->
				gen_value ctx e2;
				newline ctx;
				gen_value ctx e;
			    | _ ->
				gen_value ctx e;
				) vl;
	| TNew (c,params,el) ->
		(match c.cl_path, params with
		| (["haxe";"ds"],"StringMap"), [pt] -> print ctx "{}";
		| (["haxe";"ds"],"IntMap"), [pt] -> print ctx "{}";
		| _ -> 
		    print ctx "%s.new" (s_path ctx true c.cl_path e.epos);
		    show_args ctx el;
		);
	| TIf (cond,e,None) when (match e.eexpr with TBlock _ -> false | TIf _ -> false | _ -> true) && shortenable ->
		gen_expr ctx e;
		spr ctx " if ";
		gen_value ctx (deparent cond);
	| TIf (cond,e,eelse) ->
		spr ctx "if ";
		gen_value ctx (deparent cond);
		spr ctx " ";
		gen_expr ~preblocked:true ~postblocked:true ctx (force_block e);
		(match eelse with
		| None ->
		    newline ctx;
		    spr ctx "end";
		| Some e ->
		    (match e with 
		    | { eexpr = TIf _ } as e2 ->
			newline ctx;
			spr ctx "els";
			gen_expr ~shortenable:false ctx e2;
		    | _ ->
			newline ctx;
			spr ctx "else ";
			gen_expr ~preblocked:true ~shortenable:false ctx (force_block e)));
	| TUnop (op,Ast.Postfix,e) when op = Ast.Increment ->
		gen_value ctx e;
		spr ctx "+=1"
	| TUnop (op,Ast.Postfix,e) when op = Ast.Decrement ->
		gen_value ctx e;
		spr ctx "-=1"
	| TUnop (op,Ast.Prefix,e) when op = Ast.Increment ->
		gen_value ctx e;
		spr ctx "+=1"
	| TUnop (op,Ast.Prefix,e) when op = Ast.Decrement ->
		gen_value ctx e;
		spr ctx "-=1"
	| TUnop (op,Ast.Prefix,e) ->
		spr ctx (Ast.s_unop op);
		gen_value ctx e
	| TUnop (op,Ast.Postfix,e) ->
		gen_value ctx e;
		spr ctx (Ast.s_unop op)
	| TWhile (cond,e,Ast.NormalWhile) ->
		let handle_break = handle_break ctx e in
		spr ctx "while";
		gen_value ctx (parent cond);
		spr ctx " ";
		gen_expr ~preblocked:true ctx (force_block e);
		handle_break();
	| TWhile (cond,e,Ast.DoWhile) ->
		let handle_break = handle_break ctx e in
		spr ctx "do ";
		gen_expr ~preblocked:true ctx (force_block e);
		spr ctx " while";
		gen_value ctx (parent cond);
		handle_break();
	| TObjectDecl fields ->
		spr ctx "{ ";
		concat ctx ", " (fun (f,e) -> print ctx "%s: " (s_ident f); gen_value ctx e) fields;
		spr ctx "}"
	| TFor (v,it,e) ->
		let handle_break = handle_break ctx e in
		let tmp = gen_local ctx "_it" in
		print ctx "%s = " tmp;
		gen_value ctx it;
		newline ctx;
		print ctx "while( _hx_call(%s,:has_next) ) do %s = _hx_call(%s,:_next)" tmp (s_ident v.v_name) tmp;
		newline ctx;
		gen_expr ~preblocked:true  ~postblocked:true ctx e;
		newline ctx;
		spr ctx "end";
		handle_break();
	| TTry (e,catchs) ->
		gen_expr ~postblocked:true ctx e;
		List.iter (fun (v,e) ->
		  newline ctx;
		  let tstr = type_str ctx v.v_type e.epos in
		  if tstr <> "*" then
		    print ctx "rescue %s => %s" (type_str ctx v.v_type e.epos) (s_ident v.v_name)
		  else
		    print ctx "rescue => %s" (s_ident v.v_name);
		  gen_expr ~preblocked:true ctx e;
			  ) catchs;
	| TPatMatch dt -> assert false
	| TSwitch (e,cases,def) ->
		spr ctx "case";
		gen_value ctx (parent e);
		newline ctx;
		List.iter (fun (el,e2) ->
			List.iter (fun e ->
				spr ctx "when ";
				gen_value ctx e;
			) el;
			gen_block ctx e2;
		) cases;
		(match def with
		| None -> ()
		| Some e ->
			spr ctx "else";
			gen_block ctx e;
		);
		spr ctx "end"
	| TCast (e1,None) ->
		spr ctx "((";
		gen_expr ctx e1;
		print ctx ") as %s)" (type_str ctx e.etype e.epos);
	| TCast (e1,Some t) ->
		gen_expr ctx (Codegen.default_cast ctx.inf.com e1 t e.etype e.epos)


and gen_block ctx e =
  let b = open_block ctx in
  newline ctx;
  match e.eexpr with
  | TBlock [] -> b()
  | _ ->
      gen_expr ctx e;
      b();
      newline ctx

and gen_value ctx e =
	let assign e =
		mk (TBinop (Ast.OpAssign,
			mk (TLocal (match ctx.in_value with None -> assert false | Some r -> r)) t_dynamic e.epos,
			e
		)) e.etype e.epos
	in
	let block e =
		mk (TBlock [e]) e.etype e.epos
	in
	let value block =
		let old = ctx.in_value in
		let r = alloc_var (gen_local ctx "_r") e.etype in
		ctx.in_value <- Some r;
		if ctx.in_static then
			print ctx "lambda{ "
		else
			print ctx "lambda{|_this_| ";
		(fun() ->
		  ctx.in_value <- old;
		  if ctx.in_static then
		    print ctx "}.call()"
		  else
		    print ctx "}.call(%s)" (this ctx)
		)
	in
	match e.eexpr with
	| TCall ({ eexpr = TLocal { v_name = "__keys__" } },_) | TCall ({ eexpr = TLocal { v_name = "__hkeys__" } },_) ->
		let v = value true in
		gen_expr ctx e;
		v()
	| TConst _
	| TLocal _
	| TArray _
	| TBinop _
	| TField _
	| TEnumParameter _
	| TTypeExpr _
	| TParenthesis _
	| TObjectDecl _
	| TArrayDecl _
	| TCall _
	| TNew _
	| TUnop _
	| TFunction _ ->
		gen_expr ctx e
	| TMeta (_,e1) ->
		gen_value ctx e1
	| TCast (e1,None) ->
		let s = type_str ctx e.etype e1.epos in
		begin match s with
		| "*" ->
			gen_value ctx e1
		| "Function" ->
			spr ctx "((";
			gen_value ctx e1;
			print ctx ") as %s)" s;
		| _ ->
			print ctx "%s(" s;
			gen_value ctx e1;
			spr ctx ")";
		end
	| TCast (e1,Some t) ->
		gen_value ctx (Codegen.default_cast ctx.inf.com e1 t e.etype e.epos)
	| TReturn _
	| TBreak
	| TContinue ->
		unsupported e.epos
	| TVars _
	| TFor _
	| TWhile _
	| TThrow _ ->
		(* value is discarded anyway *)
		let v = value true in
		gen_expr ctx e;
		v()
	| TBlock [] ->
		spr ctx "nil"
	| TBlock [e] ->
		gen_value ctx e
	| TBlock el ->
		let v = value true in
		let rec loop = function
			| [] ->
				spr ctx "return nil";
			| [e] ->
				gen_expr ctx (assign e);
			| e :: l ->
				gen_expr ctx e;
				newline ctx;
				loop l
		in
		loop el;
		v();
	| TIf (cond,e,eo) ->
		spr ctx "(";
		gen_value ctx cond;
		spr ctx " ? ";
		gen_value ctx e;
		spr ctx " : ";
		(match eo with
		| None -> spr ctx "nil"
		| Some e -> gen_value ctx e);
		spr ctx ")"
	| TSwitch (cond,cases,def) ->
		let v = value true in
		gen_expr ctx (mk (TSwitch (cond,
			List.map (fun (e1,e2) -> (e1,assign e2)) cases,
			match def with None -> None | Some e -> Some (assign e)
		)) e.etype e.epos);
		v()
	| TPatMatch dt -> assert false
	| TTry (b,catchs) ->
		let v = value true in
		gen_expr ctx (mk (TTry (block (assign b),
			List.map (fun (v,e) -> v, block (assign e)) catchs
		)) e.etype e.epos);
		v()

let final m =
	if Ast.Meta.has Ast.Meta.Final m then "final " else ""

let set_public ctx public = 
  if public && ctx.protected_mode then begin
    soft_newline ctx;
    soft_newline ctx;
    spr ctx "public";
    soft_newline ctx;
    soft_newline ctx;
  end;
  if not public && not ctx.protected_mode then begin
    soft_newline ctx;
    soft_newline ctx;
    if ctx.has_statics then
	spr ctx "# protected # doesn't play well with static methods, which may be present"
    else
      spr ctx "protected";
    soft_newline ctx;
    soft_newline ctx;
  end;
  ctx.protected_mode <- not(public)

let generate_field ctx static f =
	ctx.in_static <- static;
	ctx.gen_uid <- 0;
	List.iter (fun(m,pl,_) ->
		match m,pl with
		| Ast.Meta.Meta, [Ast.ECall ((Ast.EConst (Ast.Ident n),_),args),_] ->
			let mk_arg (a,p) =
				match a with
				| Ast.EConst (Ast.String s) -> (None, s)
				| Ast.EBinop (Ast.OpAssign,(Ast.EConst (Ast.Ident n),_),(Ast.EConst (Ast.String s),_)) -> (Some n, s)
				| _ -> error "Invalid meta definition" p
			in
			print ctx "[%s" n;
			(match args with
			| [] -> ()
			| _ ->
				print ctx "(";
				concat ctx "," (fun a ->
					match mk_arg a with
					| None, s -> gen_constant ctx (snd a) (TString s)
					| Some s, e -> print ctx "%s=" s; gen_constant ctx (snd a) (TString e)
				) args;
				print ctx ")");
			print ctx "]";
		| _ -> ()
	) f.cf_meta;
	let public = f.cf_public || Hashtbl.mem ctx.get_sets (f.cf_name,static) || (f.cf_name = "main" && static) || f.cf_name = "resolve" || Ast.Meta.has Ast.Meta.Public f.cf_meta in
	(* let rights = (if static then "static " else "") ^ (if public then "public" else "# protected") in *)
	let p = ctx.curclass.cl_pos in
	set_public ctx public;
	match f.cf_expr, f.cf_kind with
	| Some { eexpr = TFunction fd }, Method (MethNormal | MethInline) ->
	    (* print ctx "%s%s " rights (if static then "" else final f.cf_meta); *)
		let rec loop c =
			match c.cl_super with
			| None -> ()
			| Some (c,_) ->
				if PMap.mem f.cf_name c.cl_fields then
					spr ctx " " (* "override " *)
				else
					loop c
		in
		if not static then loop ctx.curclass;
		soft_newline ctx;
		let h = gen_function_header ctx (Some (s_ident f.cf_name, f.cf_meta)) fd f.cf_params p false in
		let old_bc = ctx.in_block_consumer in
	        ctx.in_block_consumer <- false;
		gen_expr ~preblocked:true ctx fd.tf_expr;
		ctx.in_block_consumer <- old_bc;
		h();
		soft_newline ctx;
	| _ ->
		let is_getset = (match f.cf_kind with Var { v_read = AccCall } | Var { v_write = AccCall } -> true | _ -> false) in
		if ctx.curclass.cl_interface then
			match follow f.cf_type with
			| TFun (args,r) ->
				let rec loop = function
					| [] -> f.cf_name
					| (Ast.Meta.Getter,[Ast.EConst (Ast.String name),_],_) :: _ -> "get " ^ name
					| (Ast.Meta.Setter,[Ast.EConst (Ast.String name),_],_) :: _ -> "set " ^ name
					| _ :: l -> loop l
				in
				soft_newline ctx;
				print ctx "def %s(" (loop f.cf_meta);
				concat ctx "," (fun (arg,o,t) ->
					let tstr = type_str ctx t p in
					print ctx "%s" arg;
					if o then print ctx " = %s" (default_value tstr);
				) args;
				print ctx ") puts \"Abstract %s.%s called\" end" (tweak_class_name (snd ctx.curclass.cl_path)) (loop f.cf_meta);
			| _ when is_getset ->
				let t = type_str ctx f.cf_type p in
				let id = s_ident f.cf_name in
				(match f.cf_kind with
				| Var v ->
					(match v.v_read with
					| AccNormal -> print ctx "function get %s() : %s;" id t;
					| AccCall -> print ctx "function %s() : %s;" ("get_" ^ f.cf_name) t;
					| _ -> ());
					(match v.v_write with
					| AccNormal -> print ctx "function set %s( __v : %s ) : void;" id t;
					| AccCall -> print ctx "function %s( __v : %s ) : %s;" ("set_" ^ f.cf_name) t t;
					| _ -> ());
				| _ -> assert false)
			| _ -> ()
		else
		let gen_init () = match f.cf_expr with
			| None -> ()
			| Some e ->
				print ctx " = ";
				gen_value ctx e
		in
		if is_getset then begin
			let id = s_ident f.cf_name in
			let v = (match f.cf_kind with Var v -> v | _ -> assert false) in
 			(match v.v_read with
			| AccNormal | AccNo | AccNever ->
				soft_newline ctx;
				print ctx "def %s() @%s end" id id;
			| AccCall ->
				soft_newline ctx;
				print ctx "def %s() %s end" id ("get_" ^ f.cf_name);
			| _ -> ());
			(match v.v_write with
			| AccNormal | AccNo | AccNever ->
				soft_newline ctx;
				print ctx "def %s=(__v) @%s = __v end" id id;
			| AccCall ->
				soft_newline ctx;
				print ctx "def %s=(__v) %s(__v); end" id ("set_" ^ f.cf_name);
			| _ -> ());
			(* print ctx "%sprotected var $%s : %s" (if static then "static " else "") (s_ident f.cf_name) (type_str ctx f.cf_type p); *)
			gen_init()
		end else begin
		  (* print ctx "%s var %s : %s" rights (s_ident f.cf_name) (type_str ctx f.cf_type p); *)
		  soft_newline ctx;
		  if static then
		    begin
		      newline ctx;
		      print ctx "class << self";
		      newline ctx;
		      print ctx "attr_accessor :%s" (s_ident f.cf_name);
		      newline ctx;
		      print ctx "end";
		      newline ctx;
		    end
		  else
		    print ctx "attr_accessor :%s" (s_ident f.cf_name)
		  (* if rights <> "public" then begin
			  print ctx "protected :%s" (s_ident f.cf_name);
			  newline ctx;
			end *)
		end

let rec define_getset ctx stat c =
	let def f name =
		Hashtbl.add ctx.get_sets (name,stat) f.cf_name
	in
	let field f =
		match f.cf_kind with
		| Method _ -> ()
		| Var v ->
			(match v.v_read with AccCall -> def f ("get_" ^ f.cf_name) | _ -> ());
			(match v.v_write with AccCall -> def f ("set_" ^ f.cf_name) | _ -> ())
	in
	List.iter field (if stat then c.cl_ordered_statics else c.cl_ordered_fields);
	match c.cl_super with
	| Some (c,_) when not stat -> define_getset ctx stat c
	| _ -> ()

let generate_class ctx c =
	ctx.curclass <- c;
	define_getset ctx true c;
	define_getset ctx false c;
	ctx.local_types <- List.map snd c.cl_types;
        ctx.protected_mode <- false;
        ctx.newlined <- true;
	ctx.dirty_line <- false;
	ctx.field_names <- Hashtbl.create 0;
        ctx.has_statics <- ((List.length c.cl_ordered_statics)>0);
	List.iter (fun e -> Hashtbl.replace ctx.field_names e.cf_name true) c.cl_ordered_fields;
	let pack = open_block ctx in
	print ctx "  %s%s%s %s " (final c.cl_meta) (match c.cl_dynamic with None -> "" | Some _ -> if c.cl_interface then "" else "dynamic ") (if c.cl_interface then "class" else "class") (tweak_class_name (snd c.cl_path));
	(match c.cl_super with
	| None -> ()
	| Some (csup,_) -> print ctx "< %s " (s_path ctx true csup.cl_path c.cl_pos));
	(match c.cl_implements with
	| [] -> ()
	| l ->
	    spr ctx "";
	    (*spr ctx (if c.cl_interface then "extends " else "implements ");
		concat ctx ", " (fun (i,_) -> print ctx "%s" (s_path ctx true i.cl_path c.cl_pos)) l*));
	(* spr ctx "{"; *)
	let cl = open_block ctx in
	(match c.cl_constructor with
	| None -> ()
	| Some f ->
		let f = { f with
			cf_name = snd c.cl_path;
			cf_public = true;
			cf_kind = Method MethNormal;
		} in
		ctx.constructor_block <- true;
		generate_field ctx false f;
	);
	List.iter (generate_field ctx false) c.cl_ordered_fields;
	List.iter (generate_field ctx true) c.cl_ordered_statics;
	cl();
	newline ctx;
	spr ctx "end";
	pack();
	newline ctx;
	spr ctx "end"

let generate_main ctx inits types com =
  ctx.curclass <- { null_class with cl_path = [],"index" };
  let pack = open_block ctx in
  spr ctx "  # Hello good evening and welcome to a translation from the original Haxe";
  let rec chk_features e =
    if is_dynamic_iterator ctx e then add_feature ctx "use.$iterator";
    match e.eexpr with
    | TField (_,FClosure _) ->
	add_feature ctx "use.$bind"
    | _ ->
	Type.iter chk_features e
  in
  List.iter chk_features inits;
  newline ctx;
  if has_feature ctx "use.$iterator" then begin
    add_feature ctx "use.$bind";
    newline ctx;
    spr ctx "# some band-aids until we figure out a better translation for iterators";
    newline ctx;
    spr ctx "def _hx_iterator(o) return lambda{ (o.class == Array) ? ::Rb::RubyIterator.new(o,nil) : ((o.respond_to? 'iterator') ? o.iterator : o)} end";
    newline ctx;
    spr ctx "def _hx_call(o,k) ((o.respond_to? k) ? o.method(k).call : o[k].call) end";
    newline ctx;
  end;
  List.iter (fun c ->
    newline ctx;
    print ctx "require '%s'" (req_path c.cl_path);
	    ) types;

  (match com.main with
  | None -> ()
  | Some e -> newline ctx; gen_expr ctx e);
  pack();
  newline ctx;

  spr ctx "end"

let generate_enum ctx e =
	ctx.local_types <- List.map snd e.e_types;
	let pack = open_block ctx in
	let ename = snd e.e_path in
	print ctx "  public final class %s extends enum {" ename;
	let cl = open_block ctx in
	newline ctx;
	print ctx "public static const __isenum : Boolean = true";
	newline ctx;
	print ctx "public function %s( t : String, index : int, p : Array = nil ) : void { this.tag = t; this.index = index; this.params = p; }" ename;
	PMap.iter (fun _ c ->
		newline ctx;
		match c.ef_type with
		| TFun (args,_) ->
			print ctx "public static function %s(" c.ef_name;
			concat ctx ", " (fun (a,o,t) ->
				print ctx "%s : %s" (s_ident a) (type_str ctx t c.ef_pos);
				if o then spr ctx " = nil";
			) args;
			print ctx ") : %s {" ename;
			print ctx " return new %s(\"%s\",%d,[" ename c.ef_name c.ef_index;
			concat ctx "," (fun (a,_,_) -> spr ctx (s_ident a)) args;
			print ctx "]); }";
		| _ ->
			print ctx "public static var %s : %s = new %s(\"%s\",%d)" c.ef_name ename ename c.ef_name c.ef_index;
	) e.e_constrs;
	newline ctx;
	(match Codegen.build_metadata ctx.inf.com (TEnumDecl e) with
	| None -> ()
	| Some e ->
		print ctx "public static var __meta__ : * = ";
		gen_expr ctx e;
		newline ctx);
	print ctx "public static var __constructs__ : Array = [%s];" (String.concat "," (List.map (fun s -> "\"" ^ Ast.s_escape s ^ "\"") e.e_names));
	cl();
	newline ctx;
	print ctx "}";
	pack();
	newline ctx;
	print ctx "}";
	newline ctx

let generate_base_enum ctx =
	let pack = open_block ctx in
	spr ctx "  import flash.Boot";
	newline ctx;
	spr ctx "public class enum {";
	let cl = open_block ctx in
	newline ctx;
	spr ctx "public var tag : String";
	newline ctx;
	spr ctx "public var index : int";
	newline ctx;
	spr ctx "public var params : Array";
	newline ctx;
	spr ctx "public function toString() : String { return flash.Boot.enum_to_string(this); }";
	cl();
	newline ctx;
	print ctx "}";
	pack();
	newline ctx;
	print ctx "}";
	newline ctx

let generate com =
	let infos = {
		com = com;
	} in
	generate_resources infos;
	let ctx = init infos ([],"enum") in
	generate_base_enum ctx;
	close ctx;
	let reqs = ref [] in
	let inits = ref [] in
	List.iter (fun t ->
		match t with
		| TClassDecl c ->
			let c = (match c.cl_path with
				| ["flash"],"FlashXml__" -> { c with cl_path = [],"Xml" }
				| (pack,name) -> { c with cl_path = (pack,protect name) }
			) in
			(match c.cl_init with
			| None -> ()
			| Some e -> inits := e :: !inits);
			if c.cl_extern then
				()
			else
				let ctx = init infos c.cl_path in
				generate_class ctx c;
				reqs := !reqs @ [c];
				close ctx
		| TEnumDecl e ->
			let pack,name = e.e_path in
			let e = { e with e_path = (pack,protect name) } in
			if e.e_extern then
				()
			else
				let ctx = init infos e.e_path in
				generate_enum ctx e;
				close ctx
		| TTypeDecl _ | TAbstractDecl _ ->
			()
	) com.types;
	(match com.main with
	| None -> ()
	| Some e -> inits := e :: !inits);
	let ctx = init infos ([],"index") in
	generate_main ctx (List.rev !inits) !reqs com;
	close ctx