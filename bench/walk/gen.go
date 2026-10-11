package main

import (
	"encoding/json"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

// The tree is a list of "projects". Each project has a node_modules folder
// and a Rust target/debug folder. All sizes and counts come from a seeded
// random source, so the same seed and file count give the same tree.
//
// Shape assumptions (synthetic, not copied from a real project):
//
//   node_modules: 500 to 1100 packages, 15% under @scope folders. Each package
//   has package.json, README.md, LICENSE and a lognormal number of other files
//   (median 12, heavy tail up to 3000) spread over nested lib/dist/src style
//   folders. 8% of packages have their own nested node_modules with 1 to 4
//   packages. node_modules/.bin holds symlinks for 5% of packages. Text files
//   have a median size of about 1.5 KiB.
//
//   target/debug: 150 to 400 crates. Each crate has deps/*.rlib, *.rmeta and
//   *.d, a .fingerprint folder with 4 small files, and 25% have build-script
//   folders with an out/ folder. 12% of crates have an incremental session
//   folder with a lognormal number of small .o files (median 120).

type entry struct {
	path string
	size int64
	kind byte // 't' text, 'b' binary, 'l' symlink
	link string
}

type project struct {
	dirs    []string
	entries []entry
}

type planner struct {
	r   *rand.Rand
	p   *project
	seq int
}

func lognormal(r *rand.Rand, median, sigma float64, lo, hi int64) int64 {
	v := int64(median * math.Exp(sigma*r.NormFloat64()))
	return min(max(v, lo), hi)
}

var syllables = []string{"ab", "ar", "be", "co", "de", "el", "fa", "go", "hi", "is", "ju", "ka", "lo", "mi", "no", "or", "pa", "qu", "ri", "so", "tu", "un", "ve", "wo", "xy", "ze"}

func (pl *planner) name(n int) string {
	s := ""
	for i := 0; i < n; i++ {
		s += syllables[pl.r.IntN(len(syllables))]
	}
	pl.seq++
	return fmt.Sprintf("%s%d", s, pl.seq)
}

func (pl *planner) hash() string { return fmt.Sprintf("%016x", pl.r.Uint64()) }

func (pl *planner) dir(path string) { pl.p.dirs = append(pl.p.dirs, path) }

func (pl *planner) file(path string, size int64, kind byte) {
	pl.p.entries = append(pl.p.entries, entry{path: path, size: size, kind: kind})
}

var pkgDirs = []string{"lib", "dist", "src", "esm", "cjs", "types", "utils", "internal", "test", "build", "umd", "modules", "helpers", "core", "plugins", "locale", "fp", "es", "node", "browser"}

var pkgExts = []struct {
	ext    string
	weight int
	median float64
}{
	{".js", 55, 1500}, {".d.ts", 15, 900}, {".js.map", 10, 3000}, {".json", 5, 700},
	{".mjs", 3, 1500}, {".cjs", 2, 1500}, {".md", 5, 2500}, {".ts", 5, 1800},
}

func (pl *planner) pkgFile(dir string) {
	w := pl.r.IntN(100)
	for _, e := range pkgExts {
		if w < e.weight {
			pl.file(filepath.Join(dir, pl.name(2)+e.ext), lognormal(pl.r, e.median, 1.1, 0, 512<<10), 't')
			return
		}
		w -= e.weight
	}
}

func (pl *planner) pkg(base string, depth int) {
	pl.dir(base)
	pl.file(filepath.Join(base, "package.json"), lognormal(pl.r, 1800, 0.6, 200, 64<<10), 't')
	pl.file(filepath.Join(base, "README.md"), lognormal(pl.r, 4000, 1.0, 100, 128<<10), 't')
	pl.file(filepath.Join(base, "LICENSE"), lognormal(pl.r, 1100, 0.2, 500, 12<<10), 't')
	n := int(lognormal(pl.r, 12, 1.2, 1, 3000))
	dirs := []string{base}
	for i := 0; i < n/8; i++ {
		parent := dirs[pl.r.IntN(len(dirs))]
		d := filepath.Join(parent, pkgDirs[pl.r.IntN(len(pkgDirs))]+fmt.Sprint(i))
		pl.dir(d)
		dirs = append(dirs, d)
	}
	for i := 0; i < n; i++ {
		pl.pkgFile(dirs[pl.r.IntN(len(dirs))])
	}
	if depth < 2 && pl.r.IntN(100) < 8 {
		nm := filepath.Join(base, "node_modules")
		pl.dir(nm)
		for i, k := 0, 1+pl.r.IntN(4); i < k; i++ {
			pl.pkg(filepath.Join(nm, pl.name(3)), depth+1)
		}
	}
}

func (pl *planner) nodeModules(root string) {
	nm := filepath.Join(root, "node_modules")
	bin := filepath.Join(nm, ".bin")
	pl.dir(nm)
	pl.dir(bin)
	var scopes []string
	for i := 0; i < 20; i++ {
		s := filepath.Join(nm, "@"+pl.name(2))
		pl.dir(s)
		scopes = append(scopes, s)
	}
	for i, n := 0, 500+pl.r.IntN(600); i < n; i++ {
		parent := nm
		if pl.r.IntN(100) < 15 {
			parent = scopes[pl.r.IntN(len(scopes))]
		}
		name := pl.name(3)
		pl.pkg(filepath.Join(parent, name), 0)
		if pl.r.IntN(100) < 5 {
			rel, _ := filepath.Rel(bin, filepath.Join(parent, name, "cli.js"))
			pl.p.entries = append(pl.p.entries, entry{path: filepath.Join(bin, name), kind: 'l', link: rel})
		}
	}
}

func (pl *planner) target(root string) {
	dbg := filepath.Join(root, "target", "debug")
	deps := filepath.Join(dbg, "deps")
	fp := filepath.Join(dbg, ".fingerprint")
	build := filepath.Join(dbg, "build")
	inc := filepath.Join(dbg, "incremental")
	for _, d := range []string{filepath.Join(root, "target"), dbg, deps, fp, build, inc} {
		pl.dir(d)
	}
	pl.file(filepath.Join(root, "target", "CACHEDIR.TAG"), 177, 't')
	pl.file(filepath.Join(dbg, ".cargo-lock"), 0, 't')
	for i, n := 0, 150+pl.r.IntN(250); i < n; i++ {
		name, h := pl.name(3), pl.hash()
		pl.file(filepath.Join(deps, "lib"+name+"-"+h+".rlib"), lognormal(pl.r, 40<<10, 1.0, 4<<10, 1<<20), 'b')
		pl.file(filepath.Join(deps, "lib"+name+"-"+h+".rmeta"), lognormal(pl.r, 12<<10, 1.0, 2<<10, 512<<10), 'b')
		pl.file(filepath.Join(deps, name+"-"+h+".d"), lognormal(pl.r, 1500, 0.8, 100, 64<<10), 't')
		f := filepath.Join(fp, name+"-"+h)
		pl.dir(f)
		pl.file(filepath.Join(f, "invoked.timestamp"), 48, 't')
		pl.file(filepath.Join(f, "lib-"+name), 16, 't')
		pl.file(filepath.Join(f, "lib-"+name+".json"), lognormal(pl.r, 500, 0.4, 200, 4<<10), 't')
		pl.file(filepath.Join(f, "dep-lib-"+name), lognormal(pl.r, 300, 1.0, 20, 16<<10), 'b')
		if pl.r.IntN(100) < 25 {
			b1 := filepath.Join(build, name+"-"+pl.hash())
			pl.dir(b1)
			pl.file(filepath.Join(b1, "build-script-build"), lognormal(pl.r, 100<<10, 0.5, 32<<10, 1<<20), 'b')
			pl.file(filepath.Join(b1, "build_script_build-"+h+".d"), lognormal(pl.r, 400, 0.5, 100, 8<<10), 't')
			b2 := filepath.Join(build, name+"-"+pl.hash())
			out := filepath.Join(b2, "out")
			pl.dir(b2)
			pl.dir(out)
			pl.file(filepath.Join(b2, "invoked.timestamp"), 48, 't')
			pl.file(filepath.Join(b2, "output"), lognormal(pl.r, 300, 1.0, 0, 16<<10), 't')
			pl.file(filepath.Join(b2, "root-output"), 80, 't')
			pl.file(filepath.Join(b2, "stderr"), 0, 't')
			for j, k := 0, pl.r.IntN(20); j < k; j++ {
				pl.file(filepath.Join(out, pl.name(2)+".rs"), lognormal(pl.r, 4<<10, 1.0, 100, 256<<10), 't')
			}
		}
		if pl.r.IntN(100) < 12 {
			c := filepath.Join(inc, name+"-"+pl.hash()[:13])
			s := filepath.Join(c, "s-"+pl.hash()[:10]+"-"+pl.hash()[:7]+"-working")
			pl.dir(c)
			pl.dir(s)
			pl.file(s+".lock", 0, 't')
			pl.file(filepath.Join(s, "dep-graph.bin"), lognormal(pl.r, 80<<10, 0.8, 8<<10, 1<<20), 'b')
			pl.file(filepath.Join(s, "query-cache.bin"), lognormal(pl.r, 60<<10, 0.8, 8<<10, 1<<20), 'b')
			pl.file(filepath.Join(s, "work-products.bin"), lognormal(pl.r, 2<<10, 0.5, 100, 64<<10), 'b')
			for j, k := 0, int(lognormal(pl.r, 120, 0.8, 4, 1500)); j < k; j++ {
				pl.file(filepath.Join(s, fmt.Sprintf("%s.%s-cgu.%02d.rcgu.o", name, pl.hash()[:8], j)), lognormal(pl.r, 6<<10, 1.0, 600, 512<<10), 'b')
			}
		}
	}
}

func planProject(root string, seed uint64, i int) *project {
	pl := &planner{r: rand.New(rand.NewPCG(seed, uint64(i))), p: &project{}}
	base := filepath.Join(root, fmt.Sprintf("p%04d", i))
	pl.dir(base)
	pl.nodeModules(base)
	pl.target(base)
	return pl.p
}

var words = []string{"const", "function", "return", "export", "import", "default", "module", "require", "this", "value", "undefined", "null", "true", "false", "if", "else", "for", "while", "let", "var", "new", "class", "extends", "async", "await", "props", "state", "options", "config", "error", "result", "data", "index", "length", "push", "map", "filter", "reduce", "object", "string", "number", "type", "interface", "pub", "fn", "impl", "struct", "enum", "match", "self", "Some", "None", "Ok", "Err", "use", "crate", "{", "}", "(", ")", ";", "=>", "=", "\n"}

// content fills buf with text-like or binary-like bytes. Every file gets its
// own random stream, so no two files share content.
func content(r *rand.Rand, buf []byte, kind byte) {
	if kind == 'b' {
		for i := 0; i < len(buf); i += 8 {
			v := r.Uint64()
			if v&3 == 0 {
				v = 0 // some zero runs, like object files
			}
			for j := 0; j < 8 && i+j < len(buf); j++ {
				buf[i+j] = byte(v >> (8 * j))
			}
		}
		return
	}
	i := 0
	for i < len(buf) {
		v := r.Uint64()
		for k := 0; k < 10 && i < len(buf); k++ {
			i += copy(buf[i:], words[v&63])
			if i < len(buf) {
				buf[i] = ' '
				i++
			}
			v >>= 6
		}
	}
}

type genStats struct {
	Root     string  `json:"root"`
	Seed     uint64  `json:"seed"`
	Projects int     `json:"projects"`
	Files    int64   `json:"files"`
	Symlinks int64   `json:"symlinks"`
	Dirs     int64   `json:"dirs"`
	Bytes    int64   `json:"bytes"`
	Seconds  float64 `json:"seconds"`
}

func generate(root string, nfiles int, seed uint64, workers int) error {
	if root == "" {
		return fmt.Errorf("missing -root")
	}
	start := time.Now()
	// Plan projects until the file count is reached; cut the last one.
	var projects []*project
	total := 0
	for i := 0; total < nfiles; i++ {
		p := planProject(root, seed, i)
		if total+len(p.entries) > nfiles {
			p.entries = p.entries[:nfiles-total]
		}
		total += len(p.entries)
		projects = append(projects, p)
	}
	st := genStats{Root: root, Seed: seed, Projects: len(projects)}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	var next atomic.Int64
	var mu sync.Mutex
	var firstErr error
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, 4<<20)
			var files, links, dirs, bytes int64
			for {
				i := int(next.Add(1) - 1)
				if i >= len(projects) {
					break
				}
				p := projects[i]
				r := rand.New(rand.NewPCG(seed^0x9e3779b97f4a7c15, uint64(i)))
				err := func() error {
					for _, d := range p.dirs {
						if err := os.MkdirAll(d, 0o755); err != nil {
							return err
						}
						dirs++
					}
					for _, e := range p.entries {
						if e.kind == 'l' {
							if err := os.Symlink(e.link, e.path); err != nil {
								return err
							}
							links++
							continue
						}
						b := buf[:e.size]
						content(r, b, e.kind)
						if err := os.WriteFile(e.path, b, 0o644); err != nil {
							return err
						}
						files++
						bytes += e.size
					}
					return nil
				}()
				if err != nil {
					mu.Lock()
					if firstErr == nil {
						firstErr = err
					}
					mu.Unlock()
					return
				}
			}
			mu.Lock()
			st.Files += files
			st.Symlinks += links
			st.Dirs += dirs
			st.Bytes += bytes
			mu.Unlock()
		}()
	}
	wg.Wait()
	if firstErr != nil {
		return firstErr
	}
	st.Seconds = time.Since(start).Seconds()
	return json.NewEncoder(os.Stdout).Encode(st)
}
