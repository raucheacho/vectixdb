package vectixdb

/*
#include <stdlib.h>
#include "vectixdb.h"
*/
import "C"

import (
	"fmt"
	"time"
	"unsafe"
)

// Filter on metadata fields. Values keep their type: an Int bound only
// matches an int field, a Float bound a float field, and so on.
type Filter struct {
	kind     filterKind
	field    string
	value    Value
	lo, hi   Value
	loIncl   bool
	hiIncl   bool
	children []*Filter
}

type filterKind int

const (
	kindEq filterKind = iota
	kindRange
	kindExists
	kindAnd
	kindOr
	kindNot
)

// Eq matches a keyword (keywords: contains), int, float, bool or time field
// equal to v.
func Eq(field string, v Value) *Filter { return &Filter{kind: kindEq, field: field, value: v} }

// In matches any of the values.
func In(field string, vs ...Value) *Filter {
	fs := make([]*Filter, len(vs))
	for i, v := range vs {
		fs[i] = Eq(field, v)
	}
	return Or(fs...)
}

// Range on an int, float or time field; a nil bound is open.
func Range(field string, lo Value, loInclusive bool, hi Value, hiInclusive bool) *Filter {
	return &Filter{kind: kindRange, field: field, lo: lo, hi: hi, loIncl: loInclusive, hiIncl: hiInclusive}
}

func Gt(field string, v Value) *Filter  { return Range(field, v, false, nil, false) }
func Gte(field string, v Value) *Filter { return Range(field, v, true, nil, false) }
func Lt(field string, v Value) *Filter  { return Range(field, nil, false, v, false) }
func Lte(field string, v Value) *Filter { return Range(field, nil, false, v, true) }

// Exists matches documents that have a value for the field.
func Exists(field string) *Filter { return &Filter{kind: kindExists, field: field} }

// And matches documents matching every filter.
func And(fs ...*Filter) *Filter { return &Filter{kind: kindAnd, children: fs} }

// Or matches documents matching at least one filter.
func Or(fs ...*Filter) *Filter { return &Filter{kind: kindOr, children: fs} }

// Not matches live documents not matching f, including those without the
// field.
func Not(f *Filter) *Filter { return &Filter{kind: kindNot, children: []*Filter{f}} }

// build converts the filter to its C form; nil on invalid input.
func (f *Filter) build() *C.vtx_filter {
	if f == nil {
		return nil
	}
	switch f.kind {
	case kindEq:
		name := C.CString(f.field)
		defer C.free(unsafe.Pointer(name))
		switch v := f.value.(type) {
		case Keyword:
			p, n := cbytes(string(v))
			return C.vtx_filter_eq_keyword(name, p, n)
		case Text:
			p, n := cbytes(string(v))
			return C.vtx_filter_eq_keyword(name, p, n)
		case Int:
			return C.vtx_filter_eq_int(name, C.int64_t(v))
		case Float:
			return C.vtx_filter_eq_float(name, C.double(v))
		case Bool:
			return C.vtx_filter_eq_bool(name, cbool(bool(v)))
		case Time:
			return C.vtx_filter_eq_time(name, C.int64_t(time.Time(v).UnixMilli()))
		}
		return nil
	case kindRange:
		name := C.CString(f.field)
		defer C.free(unsafe.Pointer(name))
		var flags C.int
		if f.lo != nil {
			flags |= C.VTX_HAS_LO
			if f.loIncl {
				flags |= C.VTX_LO_INCLUSIVE
			}
		}
		if f.hi != nil {
			flags |= C.VTX_HAS_HI
			if f.hiIncl {
				flags |= C.VTX_HI_INCLUSIVE
			}
		}
		switch bound(f.lo, f.hi).(type) {
		case Int:
			return C.vtx_filter_range_int(name, C.int64_t(intOf(f.lo)), C.int64_t(intOf(f.hi)), flags)
		case Float:
			return C.vtx_filter_range_float(name, C.double(floatOf(f.lo)), C.double(floatOf(f.hi)), flags)
		case Time:
			return C.vtx_filter_range_time(name, C.int64_t(intOf(f.lo)), C.int64_t(intOf(f.hi)), flags)
		}
		return nil
	case kindExists:
		name := C.CString(f.field)
		defer C.free(unsafe.Pointer(name))
		return C.vtx_filter_exists(name)
	case kindNot:
		return C.vtx_filter_not(f.children[0].build())
	case kindAnd, kindOr:
		if len(f.children) == 0 {
			if f.kind == kindAnd {
				panic("vectixdb: And() needs at least one filter")
			}
			panic("vectixdb: Or() needs at least one filter")
		}
		acc := f.children[0].build()
		for _, c := range f.children[1:] {
			if f.kind == kindAnd {
				acc = C.vtx_filter_and(acc, c.build())
			} else {
				acc = C.vtx_filter_or(acc, c.build())
			}
		}
		return acc
	}
	panic(fmt.Sprintf("vectixdb: unknown filter kind %d", f.kind))
}

func bound(lo, hi Value) Value {
	if lo != nil {
		return lo
	}
	return hi
}

func intOf(v Value) int64 {
	switch x := v.(type) {
	case Int:
		return int64(x)
	case Time:
		return time.Time(x).UnixMilli()
	}
	return 0
}

func floatOf(v Value) float64 {
	if x, ok := v.(Float); ok {
		return float64(x)
	}
	return 0
}
