// Package vectixdb is the Go binding of VectixDB, an embedded hybrid search
// engine: vectors (HNSW), full text (BM25), exact substring and typed
// metadata filters, in one library with crash-safe storage.
//
// The static library comes with the module in release versions; in a
// checkout of the repository, build it with scripts/go-libs.sh. A DB is safe
// for concurrent use.
package vectixdb

/*
#cgo CFLAGS: -I${SRCDIR}/include
#include <stdlib.h>
#include "vectixdb.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"time"
	"unsafe"
)

// Error is returned by every failing call; compare with errors.Is against
// the Err* values.
type Error struct {
	Code int
	Msg  string
}

func (e *Error) Error() string { return "vectixdb: " + e.Msg }

// Is matches errors by code.
func (e *Error) Is(target error) bool {
	var t *Error
	return errors.As(target, &t) && t.Code == e.Code
}

var (
	ErrNoMemory = &Error{Code: -1, Msg: "out of memory"}
	ErrIO       = &Error{Code: -2, Msg: "input/output error"}
	ErrCorrupt  = &Error{Code: -3, Msg: "corrupt data"}
	ErrLocked   = &Error{Code: -4, Msg: "database locked by another process"}
	ErrReadOnly = &Error{Code: -5, Msg: "database opened read-only"}
	// ErrPoisoned: a write failed in a way that leaves its durability
	// unknown; close and reopen the database.
	ErrPoisoned = &Error{Code: -6, Msg: "database handle poisoned"}
	ErrNotFound = &Error{Code: -7, Msg: "not found"}
	ErrExists   = &Error{Code: -8, Msg: "already exists"}
	ErrInvalid  = &Error{Code: -9, Msg: "invalid argument"}
	ErrNoSpace  = &Error{Code: -10, Msg: "no space left"}
	ErrTooLarge = &Error{Code: -11, Msg: "record too large"}
	ErrClosed   = &Error{Code: -100, Msg: "database closed"}
)

// call runs a C function and reads its error message on the same OS thread
// (the message is thread-local).
func call(f func() C.int) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	rc := f()
	if rc == 0 {
		return nil
	}
	return &Error{Code: int(rc), Msg: C.GoString(C.vtx_last_error())}
}

// Version of the native library.
func Version() string { return C.GoString(C.vtx_version()) }

// Durability of writes.
type Durability int

const (
	// DurabilitySync: a write is durable when it returns.
	DurabilitySync Durability = 0
	// DurabilityNone: a write is durable after Sync, a checkpoint or Close;
	// a crash may lose the last writes, never corrupt the database.
	DurabilityNone Durability = 1
)

// Options for Open. The zero value is the default.
type Options struct {
	ReadOnly   bool
	Durability Durability
	// CheckpointAfter is the log size in bytes that triggers an automatic
	// checkpoint (0: 64 MiB).
	CheckpointAfter uint64
	// Repair drops corrupted log records instead of failing to open.
	Repair bool
}

// DB is an open database directory.
type DB struct {
	mu sync.RWMutex // guards h against Close
	h  *C.vtx_db
}

// Open opens or creates the database at path. Only one process may open it
// for writing (ErrLocked otherwise).
func Open(path string, opts *Options) (*DB, error) {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	var copts *C.vtx_options
	if opts != nil {
		copts = &C.vtx_options{
			struct_size:      C.uint32_t(unsafe.Sizeof(C.vtx_options{})),
			read_only:        cbool(opts.ReadOnly),
			durability:       C.int(opts.Durability),
			checkpoint_after: C.uint64_t(opts.CheckpointAfter),
			repair:           cbool(opts.Repair),
		}
	}
	db := &DB{}
	if err := call(func() C.int { return C.vtx_open(cpath, copts, &db.h) }); err != nil {
		return nil, err
	}
	return db, nil
}

// Close makes pending writes durable and releases the database. The handle
// is released even when an error is returned.
func (db *DB) Close() error {
	db.mu.Lock()
	defer db.mu.Unlock()
	if db.h == nil {
		return nil
	}
	h := db.h
	db.h = nil
	return call(func() C.int { return C.vtx_close(h) })
}

// with runs f with the handle under the read lock (C calls are thread safe;
// the lock only excludes Close).
func (db *DB) with(f func(h *C.vtx_db) C.int) error {
	db.mu.RLock()
	defer db.mu.RUnlock()
	if db.h == nil {
		return ErrClosed
	}
	return call(func() C.int { return f(db.h) })
}

// Sync makes every write durable (for DurabilityNone).
func (db *DB) Sync() error {
	return db.with(func(h *C.vtx_db) C.int { return C.vtx_sync(h) })
}

// Checkpoint writes snapshots and trims the log.
func (db *DB) Checkpoint() error {
	return db.with(func(h *C.vtx_db) C.int { return C.vtx_checkpoint(h) })
}

// Compact rebuilds a collection without deleted documents.
func (db *DB) Compact(collection string) error {
	c := C.CString(collection)
	defer C.free(unsafe.Pointer(c))
	return db.with(func(h *C.vtx_db) C.int { return C.vtx_compact(h, c) })
}

// Stats of the database.
type Stats struct {
	Collections   uint32 `json:"collections"`
	Documents     uint64 `json:"documents"`
	LastSeq       uint64 `json:"last_seq"`
	CheckpointSeq uint64 `json:"checkpoint_seq"`
	Generation    uint64 `json:"generation"`
	WALBytes      uint64 `json:"wal_bytes"`
}

func (db *DB) Stats() (Stats, error) {
	var s C.vtx_stats_t
	err := db.with(func(h *C.vtx_db) C.int {
		C.vtx_stats(h, &s)
		return 0
	})
	return Stats{
		Collections:   uint32(s.collections),
		Documents:     uint64(s.documents),
		LastSeq:       uint64(s.last_seq),
		CheckpointSeq: uint64(s.checkpoint_seq),
		Generation:    uint64(s.generation),
		WALBytes:      uint64(s.wal_bytes),
	}, err
}

// Count returns the number of documents in a collection.
func (db *DB) Count(collection string) (uint32, error) {
	c := C.CString(collection)
	defer C.free(unsafe.Pointer(c))
	var n C.uint32_t
	err := db.with(func(h *C.vtx_db) C.int { return C.vtx_count(h, c, &n) })
	return uint32(n), err
}

// Collections returns the collection names.
func (db *DB) Collections() ([]string, error) {
	var names *C.vtx_names
	if err := db.with(func(h *C.vtx_db) C.int { return C.vtx_collections(h, &names) }); err != nil {
		return nil, err
	}
	defer C.vtx_names_free(names)
	out := make([]string, int(C.vtx_names_len(names)))
	for i := range out {
		out[i] = C.GoString(C.vtx_names_get(names, C.size_t(i)))
	}
	return out, nil
}

// ---- schema ------------------------------------------------------------

// Metric of a vector field.
type Metric int

const (
	Cosine Metric = 0
	L2     Metric = 1
	Dot    Metric = 2
)

// FieldType of a metadata field.
type FieldType int

const (
	TypeText     FieldType = 0 // full text: BM25 and exact substring
	TypeKeyword  FieldType = 1 // one exact string
	TypeKeywords FieldType = 2 // list of exact strings
	TypeInt      FieldType = 3
	TypeFloat    FieldType = 4
	TypeBool     FieldType = 5
	TypeTime     FieldType = 6
)

type Field struct {
	Name string
	Type FieldType
}

type VectorSpec struct {
	Dim       uint32
	Metric    Metric
	Quantized bool // int8 codes, cosine only
	// M and EfConstruction: 0 for defaults (16, 200).
	M              uint32
	EfConstruction uint32
	// Tag is a free label, e.g. the embedding model.
	Tag string
}

type Schema struct {
	Vector *VectorSpec
	Fields []Field
	// BM25 parameters; zero values keep the defaults (k1 1.2, b 0.75).
	BM25K1, BM25B float32
}

// CreateCollection creates a collection (ErrExists if it exists).
func (db *DB) CreateCollection(name string, s Schema) error {
	cs := C.vtx_schema_new()
	if cs == nil {
		return ErrNoMemory
	}
	defer C.vtx_schema_free(cs)
	if err := call(func() C.int { return buildSchema(cs, s) }); err != nil {
		return err
	}
	cname := C.CString(name)
	defer C.free(unsafe.Pointer(cname))
	return db.with(func(h *C.vtx_db) C.int { return C.vtx_create_collection(h, cname, cs) })
}

func buildSchema(cs *C.vtx_schema, s Schema) C.int {
	if v := s.Vector; v != nil {
		tag := C.CString(v.Tag)
		rc := C.vtx_schema_vector(cs, C.uint32_t(v.Dim), C.int(v.Metric), cbool(v.Quantized), C.uint32_t(v.M), C.uint32_t(v.EfConstruction), tag)
		C.free(unsafe.Pointer(tag))
		if rc != 0 {
			return rc
		}
	}
	for _, f := range s.Fields {
		name := C.CString(f.Name)
		rc := C.vtx_schema_field(cs, name, C.int(f.Type))
		C.free(unsafe.Pointer(name))
		if rc != 0 {
			return rc
		}
	}
	if s.BM25K1 != 0 || s.BM25B != 0 {
		k1, b := s.BM25K1, s.BM25B
		if k1 == 0 {
			k1 = 1.2
		}
		if b == 0 {
			b = 0.75
		}
		return C.vtx_schema_bm25(cs, C.float(k1), C.float(b))
	}
	return 0
}

// DropCollection deletes a collection and its documents.
func (db *DB) DropCollection(name string) error {
	cname := C.CString(name)
	defer C.free(unsafe.Pointer(cname))
	return db.with(func(h *C.vtx_db) C.int { return C.vtx_drop_collection(h, cname) })
}

// ---- values --------------------------------------------------------------

// Value is a typed field value: Text, Keyword, Keywords, Int, Float, Bool
// or Time.
type Value interface{ fieldType() FieldType }

type (
	Text     string
	Keyword  string
	Keywords []string
	Int      int64
	Float    float64
	Bool     bool
	Time     time.Time
)

func (Text) fieldType() FieldType     { return TypeText }
func (Keyword) fieldType() FieldType  { return TypeKeyword }
func (Keywords) fieldType() FieldType { return TypeKeywords }
func (Int) fieldType() FieldType      { return TypeInt }
func (Float) fieldType() FieldType    { return TypeFloat }
func (Bool) fieldType() FieldType     { return TypeBool }
func (Time) fieldType() FieldType     { return TypeTime }

// Doc is a document: an id, an optional vector, typed fields and an opaque
// payload.
type Doc struct {
	ID      string
	Vector  []float32
	Fields  map[string]Value
	Payload []byte
}

// Op is one operation of a batch: Put or Delete.
type Op struct {
	collection string
	doc        *Doc
	deleteID   string
}

// Put inserts or replaces a document.
func Put(collection string, doc Doc) Op { return Op{collection: collection, doc: &doc} }

// Delete removes a document (no error if it does not exist).
func Delete(collection, id string) Op { return Op{collection: collection, deleteID: id} }

// Write applies the operations atomically and returns the sequence number
// of the batch.
func (db *DB) Write(ops ...Op) (uint64, error) {
	b := C.vtx_batch_new()
	if b == nil {
		return 0, ErrNoMemory
	}
	defer C.vtx_batch_free(b)
	if err := call(func() C.int { return fillBatch(b, ops) }); err != nil {
		return 0, err
	}
	var seq C.uint64_t
	err := db.with(func(h *C.vtx_db) C.int { return C.vtx_write(h, b, &seq) })
	return uint64(seq), err
}

// PutDocs is Write with one Put per document.
func (db *DB) PutDocs(collection string, docs ...Doc) (uint64, error) {
	ops := make([]Op, len(docs))
	for i := range docs {
		ops[i] = Op{collection: collection, doc: &docs[i]}
	}
	return db.Write(ops...)
}

func fillBatch(b *C.vtx_batch, ops []Op) C.int {
	for _, op := range ops {
		coll := C.CString(op.collection)
		rc := fillOp(b, coll, op)
		C.free(unsafe.Pointer(coll))
		if rc != 0 {
			return rc
		}
	}
	return 0
}

func fillOp(b *C.vtx_batch, coll *C.char, op Op) C.int {
	if op.doc == nil {
		id, n := cbytes(op.deleteID)
		return C.vtx_batch_delete(b, coll, id, n)
	}
	d := op.doc
	id, n := cbytes(d.ID)
	if rc := C.vtx_batch_put(b, coll, id, n); rc != 0 {
		return rc
	}
	if len(d.Vector) > 0 {
		if rc := C.vtx_batch_vector(b, (*C.float)(unsafe.Pointer(&d.Vector[0])), C.size_t(len(d.Vector))); rc != 0 {
			return rc
		}
	}
	if d.Payload != nil {
		var p unsafe.Pointer
		if len(d.Payload) > 0 {
			p = unsafe.Pointer(&d.Payload[0])
		}
		if rc := C.vtx_batch_payload(b, p, C.size_t(len(d.Payload))); rc != 0 {
			return rc
		}
	}
	for name, v := range d.Fields {
		cname := C.CString(name)
		rc := setField(b, cname, v)
		C.free(unsafe.Pointer(cname))
		if rc != 0 {
			return rc
		}
	}
	return 0
}

func setField(b *C.vtx_batch, name *C.char, v Value) C.int {
	switch x := v.(type) {
	case Text:
		p, n := cbytes(string(x))
		return C.vtx_batch_text(b, name, p, n)
	case Keyword:
		p, n := cbytes(string(x))
		return C.vtx_batch_keyword(b, name, p, n)
	case Keywords:
		if len(x) == 0 {
			return C.vtx_batch_keywords(b, name, nil, nil, 0)
		}
		// C memory: the arrays hold pointers.
		ptrs := (*[1 << 20]*C.char)(C.malloc(C.size_t(len(x)) * C.size_t(unsafe.Sizeof(uintptr(0)))))[:len(x):len(x)]
		lens := (*[1 << 20]C.size_t)(C.malloc(C.size_t(len(x)) * C.size_t(unsafe.Sizeof(C.size_t(0)))))[:len(x):len(x)]
		defer C.free(unsafe.Pointer(&ptrs[0]))
		defer C.free(unsafe.Pointer(&lens[0]))
		for i, s := range x {
			ptrs[i] = (*C.char)(C.CBytes([]byte(s)))
			lens[i] = C.size_t(len(s))
		}
		defer func() {
			for _, p := range ptrs {
				C.free(unsafe.Pointer(p))
			}
		}()
		return C.vtx_batch_keywords(b, name, &ptrs[0], &lens[0], C.size_t(len(x)))
	case Int:
		return C.vtx_batch_int(b, name, C.int64_t(x))
	case Float:
		return C.vtx_batch_float(b, name, C.double(x))
	case Bool:
		return C.vtx_batch_bool(b, name, cbool(bool(x)))
	case Time:
		return C.vtx_batch_time(b, name, C.int64_t(time.Time(x).UnixMilli()))
	case nil:
		return 0
	default:
		panic(fmt.Sprintf("vectixdb: unsupported value type %T", v))
	}
}

// ---- queries -------------------------------------------------------------

// Fusion of the vector and text routes.
type Fusion struct {
	// RRFK > 0 selects reciprocal rank fusion (default, k = 60).
	RRFK float32
	// Weighted fusion when RRFK is 0 and a weight is set.
	VectorWeight, TextWeight float32
}

// Query on one collection. With neither Vector nor Text, matching documents
// (Filter, Exact) are returned in insertion order.
type Query struct {
	Vector []float32
	Text   string
	// Exact is a literal substring that must appear in a text field.
	Exact string
	// TextFields restricts Text and Exact (default: every text field).
	TextFields []string
	Filter     *Filter
	K          uint32 // default 10
	Ef         uint32 // HNSW search list, default 64
	// Candidates taken from each route before fusion (default max(4K, 50)).
	Candidates uint32
	Fusion     Fusion
	// ReturnFields are copied into each result.
	ReturnFields []string
	NoPayload    bool
}

// Result of a search or Get.
type Result struct {
	ID    string
	Score float32
	// Ranks are 1-based, 0 when the route did not return the document.
	VectorRank     uint32
	VectorDistance float32
	TextRank       uint32
	TextScore      float32
	Payload        []byte
	Fields         map[string]Value
}

// Search runs a query.
func (db *DB) Search(collection string, q Query) ([]Result, error) {
	ccoll := C.CString(collection)
	defer C.free(unsafe.Pointer(ccoll))
	k := q.K
	if k == 0 {
		k = 10
	}
	cq := C.vtx_query_new(ccoll, C.uint32_t(k))
	if cq == nil {
		return nil, ErrNoMemory
	}
	defer C.vtx_query_free(cq)
	if err := call(func() C.int { return fillQuery(cq, &q) }); err != nil {
		return nil, err
	}
	var r *C.vtx_results
	if err := db.with(func(h *C.vtx_db) C.int { return C.vtx_search(h, cq, &r) }); err != nil {
		return nil, err
	}
	defer C.vtx_results_free(r)
	return readResults(r), nil
}

func fillQuery(cq *C.vtx_query, q *Query) C.int {
	if len(q.Vector) > 0 {
		if rc := C.vtx_query_vector(cq, (*C.float)(unsafe.Pointer(&q.Vector[0])), C.size_t(len(q.Vector))); rc != 0 {
			return rc
		}
	}
	if q.Text != "" {
		p, n := cbytes(q.Text)
		if rc := C.vtx_query_text(cq, p, n); rc != 0 {
			return rc
		}
	}
	if q.Exact != "" {
		p, n := cbytes(q.Exact)
		if rc := C.vtx_query_exact(cq, p, n); rc != 0 {
			return rc
		}
	}
	for _, f := range q.TextFields {
		c := C.CString(f)
		rc := C.vtx_query_text_field(cq, c)
		C.free(unsafe.Pointer(c))
		if rc != 0 {
			return rc
		}
	}
	for _, f := range q.ReturnFields {
		c := C.CString(f)
		rc := C.vtx_query_return_field(cq, c)
		C.free(unsafe.Pointer(c))
		if rc != 0 {
			return rc
		}
	}
	if q.Filter != nil {
		cf := q.Filter.build()
		if cf == nil {
			return C.VTX_E_INVALID
		}
		if rc := C.vtx_query_filter(cq, cf); rc != 0 {
			return rc
		}
	}
	if q.Ef > 0 {
		C.vtx_query_ef(cq, C.uint32_t(q.Ef))
	}
	if q.Candidates > 0 {
		C.vtx_query_candidates(cq, C.uint32_t(q.Candidates))
	}
	if q.Fusion.RRFK > 0 {
		if rc := C.vtx_query_rrf(cq, C.float(q.Fusion.RRFK)); rc != 0 {
			return rc
		}
	} else if q.Fusion.VectorWeight != 0 || q.Fusion.TextWeight != 0 {
		C.vtx_query_weighted(cq, C.float(q.Fusion.VectorWeight), C.float(q.Fusion.TextWeight))
	}
	if q.NoPayload {
		C.vtx_query_payload(cq, 0)
	}
	return 0
}

// Get returns the document with this id, or nil.
func (db *DB) Get(collection, id string) (*Result, error) {
	ccoll := C.CString(collection)
	defer C.free(unsafe.Pointer(ccoll))
	p, n := cbytes(id)
	var r *C.vtx_results
	if err := db.with(func(h *C.vtx_db) C.int { return C.vtx_get(h, ccoll, p, n, &r) }); err != nil {
		return nil, err
	}
	defer C.vtx_results_free(r)
	res := readResults(r)
	if len(res) == 0 {
		return nil, nil
	}
	return &res[0], nil
}

func readResults(r *C.vtx_results) []Result {
	n := int(C.vtx_results_len(r))
	out := make([]Result, n)
	for i := range out {
		ci := C.size_t(i)
		var l C.size_t
		id := C.vtx_result_id(r, ci, &l)
		var ex C.vtx_explain
		C.vtx_result_explain(r, ci, &ex)
		res := Result{
			ID:             C.GoStringN(id, C.int(l)),
			Score:          float32(C.vtx_result_score(r, ci)),
			VectorRank:     uint32(ex.vector_rank),
			VectorDistance: float32(ex.vector_distance),
			TextRank:       uint32(ex.text_rank),
			TextScore:      float32(ex.text_score),
		}
		if p := C.vtx_result_payload(r, ci, &l); p != nil {
			res.Payload = C.GoBytes(p, C.int(l))
		}
		if nf := int(C.vtx_result_fields(r, ci)); nf > 0 {
			res.Fields = make(map[string]Value, nf)
			for j := 0; j < nf; j++ {
				cj := C.size_t(j)
				name := C.vtx_result_field_name(r, ci, cj, &l)
				res.Fields[C.GoStringN(name, C.int(l))] = readValue(r, ci, cj)
			}
		}
		out[i] = res
	}
	return out
}

func readValue(r *C.vtx_results, i, j C.size_t) Value {
	var l C.size_t
	switch FieldType(C.vtx_result_field_type(r, i, j)) {
	case TypeText:
		s := C.vtx_result_field_str(r, i, j, &l)
		return Text(C.GoStringN(s, C.int(l)))
	case TypeKeyword:
		s := C.vtx_result_field_str(r, i, j, &l)
		return Keyword(C.GoStringN(s, C.int(l)))
	case TypeKeywords:
		n := int(C.vtx_result_field_count(r, i, j))
		ks := make(Keywords, n)
		for k := range ks {
			s := C.vtx_result_field_item(r, i, j, C.size_t(k), &l)
			ks[k] = C.GoStringN(s, C.int(l))
		}
		return ks
	case TypeInt:
		return Int(C.vtx_result_field_int(r, i, j))
	case TypeFloat:
		return Float(C.vtx_result_field_float(r, i, j))
	case TypeBool:
		return Bool(C.vtx_result_field_bool(r, i, j) != 0)
	case TypeTime:
		return Time(time.UnixMilli(int64(C.vtx_result_field_int(r, i, j))))
	}
	return nil
}

// ---- helpers -------------------------------------------------------------

func cbool(b bool) C.int {
	if b {
		return 1
	}
	return 0
}

// cbytes passes a Go string as (pointer, length). The C side copies it
// before returning and the memory holds no Go pointers, as cgo requires.
func cbytes(s string) (*C.char, C.size_t) {
	if len(s) == 0 {
		return nil, 0
	}
	return (*C.char)(unsafe.Pointer(unsafe.StringData(s))), C.size_t(len(s))
}
