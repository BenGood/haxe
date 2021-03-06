/*
 * Copyright (C)2005-2012 Haxe Foundation
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
 */
import rb.Boot;

@:keepInit
@:coreApi class Std {

	public static function is( v : Dynamic, t : Dynamic ) : Bool {
		return untyped rb.Boot.__instanceof(v,t);
	}

	public static function instance<T:{},S:T>( value : T, c : Class<S> ) : S {
		return untyped __instanceof__(v, c) ? cast v : null;
	}

	public static inline function string( s : Dynamic ) : String {
	  return untyped __dotcall__(s,"to_s");
	}

	public static inline function int( x : Float ) : Int {
		return untyped __dotcall__(x,"to_i");
	}

	public static inline function parseInt( x : String ) : Null<Int> {
	  return untyped __dotcall__(x,"to_i");
	}

	public static inline function parseFloat( x : String ) : Float {
	  return untyped __dotcall__(x,"to_f");
	}

	public static function random( x : Int ) : Int {
		return untyped x <= 0 ? 0 : Math.floor(Math.random()*x);
	}

	static function __init__() : Void untyped {
	}
}
