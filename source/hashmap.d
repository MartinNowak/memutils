﻿/**
    Internal hash map implementation.

    Copyright: Â© 2013 RejectedSoftware e.K.
    License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
    Authors: SÃ¶nke Ludwig
*/
module memutils.hashmap;

import memutils.helpers;
import memutils.allocators;
import std.conv : emplace, to;
import std.traits;
import std.algorithm : countUntil;
import memutils.refcounted;

alias HashMapRef(Key, Value, int ALLOCATOR = VulnerableAllocator) = RefCounted!(HashMapRef!(Key, Value, ALLOCATOR));

struct HashMap(Key, Value, int ALLOCATOR)
{
	@disable this(this);

	enum NOGC = true;
	alias Traits = DefaultHashMapTraits!Key;
	struct TableEntry {
		UnConst!Key key;
		Value value;
		
		this(Key key, Value value) { this.key = cast(UnConst!Key)key; this.value = value; }
	}
	private {
		TableEntry[] m_table; // NOTE: capacity is always POT
		size_t m_length;
		hash_t delegate(Key) m_hasher;
		bool m_resizing;
	}
	
	~this()
	{
		if (m_table) freeArray!(TableEntry, ALLOCATOR)(m_table);
	}
		
	@property size_t length() const { return m_length; }
	
	void remove(Key key)
	{
		logTrace("Remove key: ", Key.stringof, " val: ", Value.stringof);
		auto idx = findIndex(key);
		assert (idx != size_t.max, "Removing non-existent element.");
		auto i = idx;
		while (true) {
			m_table[i].key = Traits.clearValue;
			m_table[i].value = Value.init;
			
			size_t j = i, r;
			do {
				if (++i >= m_table.length) i -= m_table.length;
				if (Traits.equals(m_table[i].key, Traits.clearValue)) {
					m_length--;
					return;
				}
				r = m_hasher(m_table[i].key) & (m_table.length-1);
			} while ((j<r && r<=i) || (i<j && j<r) || (r<=i && i<j));
			m_table[j] = m_table[i];
		}
	}
	
	Value get(Key key, lazy Value default_value = Value.init) const
	{
		auto idx = this.findIndex(key);
		if (idx == size_t.max) return default_value;
		const Value ret = m_table[idx].value;
		return *cast(Value*)&ret;
	}
	
	Value get(in Key key, lazy Value default_value = Value.init)
	{
		auto idx = findIndex(key);
		if (idx == size_t.max) return default_value;
		return m_table[idx].value;
	}
	
	static if (!is(typeof({ Value v; const(Value) vc; v = vc; }))) {
		const(Value) get(Key key, lazy const(Value) default_value = Value.init)
		{
			auto idx = findIndex(key);
			if (idx == size_t.max) return default_value;
			return m_table[idx].value;
		}
	}
	
	void clear()
	{
		foreach (i; 0 .. m_table.length)
		if (!Traits.equals(m_table[i].key, Traits.clearValue)) {
			m_table[i].key = Traits.clearValue;
			m_table[i].value = Value.init;
		}
		m_length = 0;
	}
	
	void set(Key key, Value value) {
		opIndexAssign(value, key);
	}
	
	void opIndexAssign(Value value, Key key)
	{
		assert(!Traits.equals(key, Traits.clearValue), "Inserting clear value into hash map.");
		grow(1);
		auto i = findInsertIndex(key);
		if (!Traits.equals(m_table[i].key, key)) m_length++;
		m_table[i] = TableEntry(key, value);
	}
	
	void opIndexAssign(in Value value, in Key key)
	{
		assert(!Traits.equals(key, Traits.clearValue), "Inserting clear value into hash map.");
		grow(1);
		auto i = findInsertIndex(key);
		if (!Traits.equals(m_table[i].key, key)) m_length++;
		m_table[i] = TableEntry(*cast(Key*) &key, *cast(Value*) &value);
	}
	
	ref inout(Value) opIndex(Key key) inout {
		auto idx = findIndex(key);
		assert (idx != size_t.max, "Accessing non-existent key type: " ~ Key.stringof ~ " value: " ~ key.to!string);
		return m_table[idx].value;
	}
	
	Value opIndex(Key key) const {
		auto idx = findIndex(key);
		assert (idx != size_t.max, "Accessing non-existent key type: " ~ Key.stringof ~ " value: " ~ key.to!string);
		const Value ret = m_table[idx].value;
		return *cast(Value*) &ret;
	}
	
	inout(Value)* opBinaryRight(string op)(Key key)
	inout if (op == "in") {
		auto idx = findIndex(key);
		if (idx == size_t.max) return null;
		return &m_table[idx].value;
	}
	
	int opApply(int delegate(ref Value) del)
	{
		foreach (i; 0 .. m_table.length)
			if (!Traits.equals(m_table[i].key, Traits.clearValue))
				if (auto ret = del(m_table[i].value))
					return ret;
		return 0;
	}
	
	int opApply(int delegate(in ref Value) del)
	const {
		foreach (i; 0 .. m_table.length)
			if (!Traits.equals(m_table[i].key, Traits.clearValue))
				if (auto ret = del(m_table[i].value))
					return ret;
		return 0;
	}
	
	int opApply(int delegate(in ref Key, ref Value) del)
	{
		foreach (i; 0 .. m_table.length)
			if (!Traits.equals(m_table[i].key, Traits.clearValue))
				if (auto ret = del(m_table[i].key, m_table[i].value))
					return ret;
		return 0;
	}
	
	int opApply(int delegate(ref Key, ref Value) del)
	{
		foreach (i; 0 .. m_table.length)
			if (!Traits.equals(m_table[i].key, Traits.clearValue))
				if (auto ret = del(m_table[i].key, m_table[i].value))
					return ret;
		return 0;
	}
	
	int opApply(int delegate(in ref Key, in ref Value) del)
	const {
		foreach (i; 0 .. m_table.length)
			if (!Traits.equals(m_table[i].key, Traits.clearValue))
				if (auto ret = del(m_table[i].key, m_table[i].value))
					return ret;
		return 0;
	}
	
	private size_t findIndex(in Key key)
	const {
		
		if (m_length == 0) return size_t.max;
		size_t start = m_hasher(*cast(Key*) &key) & (m_table.length-1);
		auto i = start;
		while (!Traits.equals(m_table[i].key, key)) {
			if (Traits.equals(m_table[i].key, Traits.clearValue)) return size_t.max;
			if (++i >= m_table.length) i -= m_table.length;
			if (i == start) return size_t.max;
		}
		return i;
	}
	
	private size_t findInsertIndex(in Key key)
	const {
		auto hash = m_hasher(*cast(Key*) &key);
		size_t target = hash & (m_table.length-1);
		auto i = target;
		while (!Traits.equals(m_table[i].key, Traits.clearValue) && !Traits.equals(m_table[i].key, key)) {
			if (++i >= m_table.length) i -= m_table.length;
			assert (i != target, "No free bucket found, HashMap full!?");
		}
		return i;
	}
	
	private void grow(size_t amount)
	{
		auto newsize = m_length + amount;
		if (newsize < (m_table.length*2)/3) return;
		auto newcap = m_table.length ? m_table.length : 16;
		while (newsize >= (newcap*2)/3) newcap *= 2;
		resize(newcap);
	}
	
	private void resize(size_t new_size)
	{
		assert(!m_resizing);
		m_resizing = true;
		scope(exit) m_resizing = false;
		
		if (!m_hasher) {
			
			
			static if ((__traits(hasMember, Key, "isRefCounted") && __traits(hasMember, typeof(*(Key())), "toArray") ) ||
				__traits(hasMember, Key, "toArray"))
			{
				m_hasher = (Key k) {
					import std.typecons : scoped;
					import botan.hash.md4; // fixme: use xxhash
					import memutils.vector : Array;
					Array!ubyte s = k.toArray();
					auto md4 = scoped!MD4();
					md4.update(s);
					auto hash = md4.finished();
					return *cast(size_t*)hash.ptr;
				};
			}
			else static if ((__traits(hasMember, Key, "isRefCounted") && __traits(hasMember, typeof(*(Key())), "toVector") ) ||
				__traits(hasMember, Key, "toVector"))
			{
				m_hasher = (Key k) {
					import std.typecons : scoped;
					import botan.hash.md4;
					import memutils.vector : Array;
					Vector!ubyte s = k.toVector();
					auto md4 = scoped!MD4();
					md4.update(s);
					auto hash = md4.finished();
					return *cast(size_t*)hash.ptr;
				};
			}
			else static if (( __traits(hasMember, Key, "isRefCounted") && __traits(hasMember, typeof(*(Key())), "toString") ) ||
				__traits(hasMember, Key, "toString"))
			{
				m_hasher = (Key k) {
					import std.typecons : scoped;
					import botan.hash.md4;
					string s = k.toString();
					auto md4 = scoped!MD4();
					md4.update(s);
					auto hash = md4.finished();
					return *cast(size_t*)hash.ptr;
				};
			}
			
			else static if (__traits(compiles, (){ Key t; size_t hash = t.toHash(); }())) {
				static if (isPointer!Key || is(Unqual!Key == class)) m_hasher = k => k ? k.toHash() : 0;
				else m_hasher = k => k.toHash();
			} else static if (__traits(compiles, (){ Key t; size_t hash = t.toHashShared(); }())) {
				static if (isPointer!Key || is(Unqual!Key == class)) m_hasher = k => k ? k.toHashShared() : 0;
				else m_hasher = k => k.toHashShared();
			} 
			else static if (__traits(hasMember, Key, "isRefCounted")) {
				
				auto typeinfo = typeid(typeof(*(Key())));
				m_hasher = k => typeinfo.getHash(&k);
			}
			else {
				auto typeinfo = typeid(Key);
				m_hasher = k => typeinfo.getHash(&k);
			}
		}
		
		uint pot = 0;
		while (new_size > 1) pot++, new_size /= 2;
		new_size = 1 << pot;
		
		auto oldtable = m_table;
		m_table = allocArray!(TableEntry, ALLOCATOR)(new_size);
		foreach (ref el; m_table) {
			static if (is(Key == struct)) {
				emplace(cast(UnConst!Key*)&el.key);
				static if (Traits.clearValue !is Key.init)
					el.key = cast(UnConst!Key)Traits.clearValue;
			} else el.key = cast(UnConst!Key)Traits.clearValue;
			emplace(&el.value);
		}
		foreach (ref el; oldtable)
		if (!Traits.equals(el.key, Traits.clearValue)) {
			auto idx = findInsertIndex(el.key);
			(cast(ubyte[])(&m_table[idx])[0 .. 1])[] = (cast(ubyte[])(&el)[0 .. 1])[];
		}
		if (oldtable) freeArray!(TableEntry, ALLOCATOR, true, false)(oldtable);
	}
}


struct DefaultHashMapTraits(Key) {
	enum clearValue = Key.init;
	static bool equals(in Key a, in Key b)
	{
		static if (__traits(hasMember, Key, "isRefCounted") && 
			is (typeof(*(Key())) == class) && 
			__traits(compiles, "bool c = a.opEquals(b);"))
		{
			if (a is null && b !is null) {
				return b.opEquals(a);
			}
			else if (a !is null && b is null) {
				return a.opEquals(b);
			}
			else if (a !is null && b !is null) // both are equally null
			{
				
				return a.opEquals(b);
			}
			else {
				return true;
			}
		}
		else static if (__traits(hasMember, Key, "isRefCounted") && is (typeof(*(Key())) == class)) {
			return *a is *b;
		}
		else {
			return a == b;
		}
	}
}