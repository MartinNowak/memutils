﻿module memutils.utils;

import core.thread : Fiber;	
import std.traits : isPointer, hasIndirections, hasElaborateDestructor;
import std.conv : emplace;
import std.c.string : memset;
import memutils.allocators;
import std.algorithm : startsWith;
public import memutils.constants;

FiberPool getFiberPool(Fiber f) {
	assert(f);

	if (auto ptr = (f in g_fiberAlloc)) 
	{
		return *ptr;
	}
	else {
		auto ret = new FiberPool();
		g_fiberAlloc[f] = ret;
		return ret;
	}
}

void destroyFiberPool(Fiber f = Fiber.getThis()) {
	if (auto ptr = (f in g_fiberAlloc)) {
		static if (typeof(ptr).stringof.startsWith("DebugAllocator")) {
			ptr.m_baseAlloc.freeAll();
			delete *ptr;
		}
		else ptr.freeAll();
		g_fiberAlloc.remove(f);
	}
	else logError("Fiber not found");
}
import std.traits : isArray;

struct GC {
	mixin ConvenienceAllocators!NativeGC;
}

struct ThisFiber {
	mixin ConvenienceAllocators!ScopedFiberPool;
}

struct ThisThread {
	mixin ConvenienceAllocators!LocklessFreeList;
}

struct SecureMem {
	mixin ConvenienceAllocators!CryptoSafe;
}

package struct Malloc {
	enum ident = Mallocator;
}

package:

template ObjectAllocator(T, ALLOC)
{
	import core.memory : GC;
	enum ElemSize = AllocSize!T;
	
	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;

	alias TR = RefTypeOf!T;
	
	TR alloc(ARGS...)(ARGS args)
	{
		//logInfo("alloc %s/%d", T.stringof, ElemSize);
		auto mem = getAllocator!(ALLOC.ident)().alloc(ElemSize);
		static if ( hasIndirections!T && !NOGC ) GC.addRange(mem.ptr, ElemSize, typeid(T));
		return emplace!T(mem, args);
	}
	
	void free(TR obj)
	{
		auto objc = obj;
		static if (is(TR == T*)) .destroy(*objc);
		else .destroy(objc);

		static if( hasIndirections!T && !NOGC ) GC.removeRange(cast(void*)obj);
		getAllocator!(ALLOC.ident)().free((cast(void*)obj)[0 .. ElemSize]);
	}
}

/// Allocates an array without touching the memory.
T[] allocArray(T, ALLOC = ThisThread)(size_t n)
{
	import core.memory : GC;
	mixin(translateAllocator());
	auto allocator = thisAllocator();
	auto mem = allocator.alloc(T.sizeof * n);
	auto ret = cast(T[])mem;

	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;
	
	static if( hasIndirections!T && !NOGC )
		GC.addRange(mem.ptr, mem.length, typeid(T));
	// don't touch the memory - all practical uses of this function will handle initialization.
	return ret;
}

T[] reallocArray(T, ALLOC = ThisThread)(T[] array, size_t n) {
	import core.memory : GC;
	assert(n > array.length, "Cannot reallocate to smaller sizes");
	mixin(translateAllocator());
	auto allocator = thisAllocator();
	auto mem = allocator.realloc(cast(void[]) array, T.sizeof * n);
	auto ret = cast(T[])mem;
	
	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;
	
	static if (hasIndirections!T && !NOGC) {
		if (ret.ptr != array.ptr) {
			GC.removeRange(array.ptr);
			GC.addRange(ret.ptr, ret.length, typeid(T));
		}
		// Zero out unused capacity to prevent gc from seeing false pointers
		memset(ret.ptr + array.length, 0, (n - array.length) * T.sizeof);
	}
	
	return ret;
}

void freeArray(T, ALLOC = ThisThread)(ref T[] array, size_t max_destroy = size_t.max)
{
	import core.memory : GC;
	mixin(translateAllocator());
	auto allocator = thisAllocator();
	
	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;
	
	static if (hasIndirections!T && !NOGC) {
		GC.removeRange(array.ptr);
	}

	static if (hasElaborateDestructor!T) { // calls destructors
		size_t i;
		foreach (ref e; array) {
			static if (is(T == struct) && isPointer!T) .destroy(*e);
			else .destroy(e);
			if (++i == max_destroy) break;
		}
	}
	allocator.free(cast(void[])array);
	array = null;
}

mixin template ConvenienceAllocators(alias ALLOC) {
	package enum ident = ALLOC;

	// objects
	auto alloc(T, ARGS...)(ARGS args) 
		if (!isArray(T))
	{
		return ObjectAllocator!(T, ALLOC).alloc(args);
	}
	
	void free(T)(T* obj)
		if (!isArray!T && !is(T : Object))
	{
		return ObjectAllocator!(T, ALLOC).free(obj);
	}
	
	void free(T)(T obj)
		if (!isArray!T && is(T  : Object))
	{
		return ObjectAllocator!(T, ALLOC).free(obj);
	}

	/// arrays
	auto alloc(T, ARGS...)(ARGS args)
		if (isArray(T))
	{
		return allocArray!(T, ALLOC).alloc(args);
	}
	
	auto realloc(T)(T arr)
		if (isArray!T)
	{
		return reallocArray!(T, ALLOC);
	}
	
	void free(T)(T arr)
		if (isArray!T)
	{
		return freeArray!(T, ALLOC);
	}

}

string translateAllocator() { /// requires (ALLOC) template parameter
	return `
	static assert(ALLOC.ident, "The 'ALLOC' template parameter is not in scope.");
	ReturnType!(getAllocator!(ALLOC.ident)) thisAllocator() {
		return getAllocator!(ALLOC.ident)();
	}`;
}