package vectixdb

import (
	"errors"
	"fmt"
	"math/rand"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func openTemp(t *testing.T) (*DB, string) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "db")
	db, err := Open(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	return db, dir
}

var notes = Schema{
	Vector: &VectorSpec{Dim: 3, Tag: "test"},
	Fields: []Field{
		{Name: "body", Type: TypeText},
		{Name: "lang", Type: TypeKeyword},
		{Name: "tags", Type: TypeKeywords},
		{Name: "version", Type: TypeInt},
		{Name: "score", Type: TypeFloat},
		{Name: "at", Type: TypeTime},
	},
}

func seed(t *testing.T, db *DB) {
	t.Helper()
	if err := db.CreateCollection("notes", notes); err != nil {
		t.Fatal(err)
	}
	at := time.UnixMilli(1_700_000_000_000)
	_, err := db.PutDocs("notes",
		Doc{ID: "a", Vector: []float32{1, 0, 0}, Payload: []byte("fix-a"), Fields: map[string]Value{
			"body": Text("Metro cannot resolve module, clear the cache"), "lang": Keyword("en"),
			"tags": Keywords{"expo", "metro"}, "version": Int(52), "score": Float(0.9), "at": Time(at),
		}},
		Doc{ID: "b", Vector: []float32{0.9, 0.1, 0}, Fields: map[string]Value{
			"body": Text("Erreur de résolution du module Metro"), "lang": Keyword("fr"),
			"tags": Keywords{"metro"}, "version": Int(51), "score": Float(1.0000001),
		}},
		Doc{ID: "c", Vector: []float32{0, 1, 0}, Fields: map[string]Value{
			"body": Text("zig build fails with ERR_LINK_FAILED"), "lang": Keyword("en"), "score": Float(1),
		}},
	)
	if err != nil {
		t.Fatal(err)
	}
}

func ids(rs []Result) []string {
	out := make([]string, len(rs))
	for i, r := range rs {
		out[i] = r.ID
	}
	return out
}

func TestEndToEnd(t *testing.T) {
	db, dir := openTemp(t)
	seed(t, db)

	rs, err := db.Search("notes", Query{Vector: []float32{1, 0.05, 0}, Text: "metro module", K: 2, ReturnFields: []string{"version", "tags"}})
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(ids(rs)) != "[a b]" {
		t.Fatalf("hybrid: got %v", ids(rs))
	}
	if rs[0].VectorRank != 1 || rs[0].TextRank == 0 || string(rs[0].Payload) != "fix-a" {
		t.Fatalf("explain/payload: %+v", rs[0])
	}
	if rs[0].Fields["version"] != Int(52) || len(rs[0].Fields["tags"].(Keywords)) != 2 {
		t.Fatalf("fields: %+v", rs[0].Fields)
	}

	cases := []struct {
		f    *Filter
		want string
	}{
		{Eq("lang", Keyword("en")), "[a c]"},
		{Eq("tags", Keyword("expo")), "[a]"},
		{In("version", Int(51), Int(99)), "[b]"},
		{Gt("score", Float(1.00000005)), "[b]"},
		{Lte("score", Float(1)), "[a c]"},
		{And(Eq("lang", Keyword("en")), Not(Exists("tags"))), "[c]"},
		{Gte("at", Time(time.UnixMilli(1_700_000_000_000))), "[a]"},
	}
	for _, c := range cases {
		rs, err := db.Search("notes", Query{Filter: c.f, K: 10})
		if err != nil {
			t.Fatal(err)
		}
		if got := fmt.Sprint(ids(rs)); got != c.want {
			t.Errorf("filter %+v: got %s, want %s", c.f, got, c.want)
		}
	}

	rs, err = db.Search("notes", Query{Exact: "ERR_LINK_FAILED"})
	if err != nil || fmt.Sprint(ids(rs)) != "[c]" {
		t.Fatalf("exact: %v %v", ids(rs), err)
	}
	rs, err = db.Search("notes", Query{Text: "err_link_failed"})
	if err != nil || fmt.Sprint(ids(rs)) != "[c]" {
		t.Fatalf("identifier search: %v %v", ids(rs), err)
	}

	if _, err := db.Search("notes", Query{Filter: Eq("version", Float(52))}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("type mismatch must be invalid, got %v", err)
	}
	if _, err := db.PutDocs("notes", Doc{ID: "x", Vector: []float32{1}}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("bad dimension must be invalid, got %v", err)
	}
	if _, err := db.Search("nope", Query{Text: "x"}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing collection: %v", err)
	}
	if _, err := Open(dir, nil); !errors.Is(err, ErrLocked) {
		t.Fatalf("second open must be locked, got %v", err)
	}

	if _, err := db.Write(Delete("notes", "a"), Put("notes", Doc{ID: "d", Fields: map[string]Value{"body": Text("new")}})); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Count("notes"); !errors.Is(err, ErrClosed) {
		t.Fatalf("closed: %v", err)
	}

	db, err = Open(dir, &Options{ReadOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if n, _ := db.Count("notes"); n != 3 {
		t.Fatalf("count after reopen: %d", n)
	}
	got, err := db.Get("notes", "b")
	if err != nil || got == nil || got.Fields["body"] != Text("Erreur de résolution du module Metro") {
		t.Fatalf("get: %+v %v", got, err)
	}
	if got, _ := db.Get("notes", "a"); got != nil {
		t.Fatal("deleted document still present")
	}
	if _, err := db.PutDocs("notes", Doc{ID: "z"}); !errors.Is(err, ErrReadOnly) {
		t.Fatalf("read-only: %v", err)
	}
	if names, _ := db.Collections(); fmt.Sprint(names) != "[notes]" {
		t.Fatalf("collections: %v", names)
	}
}

func TestConcurrentReadersAndWriter(t *testing.T) {
	db, _ := openTemp(t)
	defer db.Close()
	if err := db.CreateCollection("v", Schema{Vector: &VectorSpec{Dim: 8}, Fields: []Field{{Name: "n", Type: TypeInt}}}); err != nil {
		t.Fatal(err)
	}
	vec := func(r *rand.Rand) []float32 {
		v := make([]float32, 8)
		for i := range v {
			v[i] = float32(r.NormFloat64())
		}
		return v
	}
	var wg sync.WaitGroup
	errs := make(chan error, 16)
	wg.Add(1)
	go func() {
		defer wg.Done()
		r := rand.New(rand.NewSource(1))
		for i := 0; i < 500; i++ {
			if _, err := db.PutDocs("v", Doc{ID: fmt.Sprint(i), Vector: vec(r), Fields: map[string]Value{"n": Int(i)}}); err != nil {
				errs <- err
				return
			}
		}
	}()
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			r := rand.New(rand.NewSource(int64(g + 10)))
			for i := 0; i < 200; i++ {
				if _, err := db.Search("v", Query{Vector: vec(r), K: 5, Filter: Gte("n", Int(10))}); err != nil {
					errs <- err
					return
				}
			}
		}(g)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	if n, _ := db.Count("v"); n != 500 {
		t.Fatalf("count: %d", n)
	}
}

func BenchmarkHybridSearch(b *testing.B) {
	dir := filepath.Join(b.TempDir(), "db")
	db, err := Open(dir, &Options{Durability: DurabilityNone})
	if err != nil {
		b.Fatal(err)
	}
	defer db.Close()
	const dim, n = 384, 20000
	if err := db.CreateCollection("c", Schema{Vector: &VectorSpec{Dim: dim, Quantized: true}, Fields: []Field{{Name: "body", Type: TypeText}}}); err != nil {
		b.Fatal(err)
	}
	r := rand.New(rand.NewSource(1))
	words := []string{"metro", "cache", "zig", "build", "error", "module", "resolve", "expo", "linker", "token"}
	vec := func() []float32 {
		v := make([]float32, dim)
		for i := range v {
			v[i] = float32(r.NormFloat64())
		}
		return v
	}
	docs := make([]Doc, 0, 500)
	for i := 0; i < n; i++ {
		body := fmt.Sprintf("%s %s %s doc%d", words[r.Intn(10)], words[r.Intn(10)], words[r.Intn(10)], i)
		docs = append(docs, Doc{ID: fmt.Sprint(i), Vector: vec(), Fields: map[string]Value{"body": Text(body)}})
		if len(docs) == cap(docs) {
			if _, err := db.PutDocs("c", docs...); err != nil {
				b.Fatal(err)
			}
			docs = docs[:0]
		}
	}
	q := vec()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := db.Search("c", Query{Vector: q, Text: "metro cache", K: 10, NoPayload: true}); err != nil {
			b.Fatal(err)
		}
	}
}
