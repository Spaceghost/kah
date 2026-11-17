# Kah

Kah compiles a Ruby subset to portable Lua source. It uses **Ruby's Prism
parser through matz/spinel**, with a new backend before Spinel's native C
analysis. The generated file includes a small Ruby compatibility runtime and
runs without Ruby, Spinel, or Kah installed on the destination machine.

Kah is an early prototype, version 0.1.0. It is not a complete Ruby
implementation. It makes no performance claims. The current implementation
prioritizes Ruby behavior across Lua and LuaJIT over optimizing generated code.

## Build

Clone [Spaceghost/kah](https://github.com/Spaceghost/kah), then build with a C
compiler, Make, curl, tar, and Ruby available:

```sh
git clone https://github.com/Spaceghost/kah.git
cd kah
make deps
make -j4 kah
./bin/kah --version
```

`make deps` fetches Prism 1.9.0 and RBS from RubyGems. The build reuses Spinel's
native compiler; Ruby runs the existing build generators. Kah embeds Prism and
the Lua compatibility runtime in its compiler binary. No RubyGem installation
or Ruby process is needed when compiling or running programs afterward.

For a user-local standalone installation:

```sh
make install-kah PREFIX="$HOME/.local"
```

Python 3 is needed only for the optional test and website build scripts.

## Compile and run

```sh
./bin/kah examples/kah/hello.rb -o hello.lua
lua hello.lua
luajit hello.lua
```

Both print:

```text
Hello from Kah
42
```

Kah emits Lua 5.1 syntax. The verification suite exercises the identical output
on Lua 5.1, Lua 5.4, Lua 5.5, and LuaJIT 2.1 when those interpreters are available.
This is source portability; Lua and LuaJIT bytecode formats are not interchangeable.

```sh
./bin/kah -E examples/kah/hello.rb
./bin/kah --target=luajit -E examples/kah/hello.rb
./bin/kah --lua=lua5.4 -E examples/kah/hello.rb
./bin/kah -e 'puts 7 / 2'
./bin/kah examples/kah/hello.rb -S
```

With `-E`, compiler options precede the Ruby file. Subsequent arguments become
Ruby's `ARGV`. `--lua=PATH` selects an executable, not a shell command.

`spinel --target=lua` and `spinel --target=luajit` select the same backend.
The `kah` executable selects Lua by default; `spinel` keeps its native default.
C link inputs, native extension options, analysis output modes, and incremental
native builds are rejected for a Lua target.
Existing files that Kah did not generate need `--force` to overwrite. The Ruby
input cannot be overwritten, including through a symlink or hard link.

## Supported language

- Nil, booleans, integers, floats, byte strings, symbols, arrays, hashes, and
  bounded integer ranges. Arrays retain nil entries and use Ruby's zero-based
  and negative indexes. Hashes support scalar keys, including nil/false, and retain insertion order.
- Local, instance, global, and constant variables; constant paths; assignment,
  numeric compound assignment, `||=`, and `&&=` for locals, ivars, and globals.
- Methods with required, optional, rest, and block parameters; recursive calls;
  implicit and explicit return; string interpolation; safe navigation;
  short-circuit `&&` and `||`; `if`, `elsif`, `unless`, `while`, `until`, and
  post-test loops. `break` and `next` carry values.
- Classes, inheritance, modules, `include`, constructors, singleton methods,
  and `attr_reader`, `attr_writer`, and `attr_accessor`.
- Literal blocks, lexical captures, numbered parameters, Ruby 3.4 `it`, `yield`,
  `block_given?`, `&block` capture and forwarding, and nonlocal return/break.

The compatibility runtime implements a limited selection of core methods:

| Area | Methods |
| --- | --- |
| Output | `puts`, `print`, `p`, basic `raise` |
| Numbers | Arithmetic, comparisons, `to_i`, `to_f`, `abs`, `zero?`, `even?`, `odd?`, `times`, `upto`, `downto` |
| Arrays | Indexing and indexed assignment, `size`, `length`, `empty?`, `first`, `last`, `push`, `<<`, `pop`, `join`, `to_a`, `Array.new` |
| Hashes | Lookup and assignment, `size`, `length`, `empty?`, `key?`, `has_key?`, `keys`, `values`, `Hash.new` without defaults |
| Iteration | `each`, `each_with_index`, `map`, `collect`, `select`, integer range `to_a` |
| Strings | `+`, `*`, ASCII `upcase`/`downcase`, byte indexing, `bytesize`, byte `length`, `empty?`, decimal `to_i`, `to_sym` |

Method names above describe the implemented forms, not every overload or every
Ruby edge case. Unsupported syntax is refused with a source path and line
before output is written. Unknown runtime methods raise an error.

## Lua interoperability

```ruby
math = Lua.require("math")
puts math.sqrt(81).to_i
puts Lua.global("type").call("kah")
```

`Lua.require` uses the running VM's normal package loader. `Lua.global` exposes
a Lua global. Proxy method calls invoke module functions; `proxy[key]` reads
Lua table keys using Lua's own indexes. A Lua function proxy supports `call`.
This preserves access to the selected VM's libraries, including LuaJIT-only
modules when running on LuaJIT.

Lua numbers enter Ruby as Floats. Nil, booleans, and strings cross directly.
Tables and functions become proxies. Ruby arrays/hashes passed to native Lua
functions are copied to Lua tables; mutation of that copy does not update the
Ruby container. A native call currently takes only its first Lua return value.
Ruby block values can be passed as function arguments to Lua APIs. These are
explicit boundaries, not shared Ruby and Lua object identity.

A compiled chunk also returns an export adapter for a Lua host:

```lua
local kah = assert(loadfile("hello.lua"))() -- runs the Ruby top level
print(kah.call("twice", 21))
```

## Current limits

Portable integers are exact only in `-9007199254740991..9007199254740991`, the
shared safe range for standard double-based Lua 5.1 and LuaJIT. Larger literals
are compile errors and overflowing integer results raise `RangeError`.
Floats are boxed so `7 / 2` produces `3` and `7.0 / 2` produces `3.5` on every
VM. Arbitrary precision integers and Rational are not implemented.

Strings are immutable, byte-oriented Lua strings. Ruby encoding, Unicode
character indexing/casing, mutable string aliasing, and frozen-string semantics
are not implemented. Float formatting and object inspection cover the tested
subset, not CRuby's complete formatting and encoding behavior.

The prototype does not implement exception rescue/ensure, runtime Ruby `eval`,
RubyGems or native extensions, regular expressions, `case`/pattern matching,
`for`, multiple assignment, lambdas, `super`, keyword or post-rest parameters,
splats, class variables, visibility enforcement, refinements, threads, fibers,
custom or composite Hash key semantics, or the full Ruby standard library. Spinel's local source resolver is reused;
there is no general Ruby library compatibility promise.

The runtime uses protected calls for Ruby's nonlocal control flow and a
per-activation temporary table. A Lua target intentionally skips Spinel's
native type-inference optimizations. Performance tuning and broader Ruby
compatibility are future work, not properties of this initial backend.

## Verify

```sh
make kah-test
# Explicit interpreter set, when they are on PATH:
LUA_VMS='lua5.1 luajit lua5.4 lua5.5' make kah-test
```

The suite compares complete program output against CRuby, compiles each Ruby
fixture once, and runs that same Lua file on every detected VM. It requires
both LuaJIT and at least one standard Lua interpreter. It also checks compile
refusals, input/output protection, runner arguments, missing interpreters, Lua
module calls, and the existing native C backend's source generation.

## Foundations and license

Kah builds on [matz/spinel](https://github.com/matz/spinel) and
[ruby/prism](https://github.com/ruby/prism). The inherited MIT license and
attributions remain in this repository. The Kah additions use that same license.
