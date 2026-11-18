# Kah: Ruby + Nelua

Kah 0.2 builds a native compiler from two implementation languages:

- **Ruby**, compiled ahead of time by Spinel, owns the CLI, local source loading,
  compiler policy, Ruby-to-Lua lowering, and output generation.
- **Nelua** owns Prism object lifetimes, typed AST access, binary string transfer,
  file identity checks, temporary files, and process execution.

Prism remains the Ruby parser. The Lua compatibility runtime remains Lua because
it is embedded in the programs Kah produces. The installed compiler runs without
Ruby, Spinel, Nelua, a Prism gem, or support source files on PATH.

## Build and execution

```text
compiler/*.rb                  compiler/native/*.nelua
      | Spinel                          | Nelua
      v                                 v
 generated compiler C             generated native object
                \                  /
                 link with Prism + Spinel runtime
                              |
                          native kah
                              |
                  Ruby file --Prism--> Ruby compiler logic
                              |
                     self-contained Lua file
                              |
                   Lua 5.1 / 5.4 / 5.5 / LuaJIT
```

Both compilers currently generate C as an intermediate representation. Generated
C is a build artifact. Kah's authored compiler implementation contains no C/C++
source, C headers, or inline C adapters.

## What replaced the old C path

| Responsibility | Current source | Previous implementation |
| --- | --- | --- |
| CLI, output safeguards, options | `compiler/kah.rb` | Kah branches in Spinel's `src/main.c` |
| Compiler logic and Lua emission | `compiler/lua_emitter.rb` | `src/codegen_lua.c`, now removed |
| Typed Prism access and ownership | `compiler/native/prism.nelua` | Spinel's C AST flattening and node table, no longer used by Kah |
| Process runner, temp files, file identity | `compiler/native/platform.nelua` | C driver support |
| Ruby/native declarations | `compiler/native.rb` | Direct declarations spread across the old backend |

`tools/gen_kah_prism.rb` reads the pinned Prism public AST header and generates
Nelua declarations and typed field accessors. The resulting code stays in the
build directory. The adapter imports Prism's real C declarations, allowing the C
compiler to use the SDK's actual layouts. It does not guess byte offsets.

The Native ABI carries an owned context pointer, node IDs, scalar fields, and
strings. Node IDs are Prism's parser-assigned IDs and never encode pointer
addresses. Every query validates the node ID. A context copies the Ruby source
before Prism retains it, and closing the context destroys the AST, parser,
source buffer, text buffer, and node index. Ruby closes contexts through `ensure`.

Binary text uses Spinel's documented `:binstr` FFI contract. The Nelua adapter
publishes the exact length in `sp_ffi_bin_len`; Spinel copies that many bytes into
a Ruby string before the next query. Embedded NUL and UTF-8 bytes survive the
boundary. It does not retain a borrowed Ruby string pointer across calls.

Local `require_relative` and `require` loading is implemented in Ruby. Each
required file gets its own locals and a generated lazy loader. The generated
program runs each feature once, including cyclic imports. `-I` adds local search
roots. Computed Ruby requires and RubyGems remain unsupported.

## The C that remains

The source audit classifies these dependencies explicitly:

1. **Prism:** the upstream C parser requested for Kah.
2. **Spinel runtime:** GC, strings, arrays, exceptions, and other support required
   by Spinel-generated Ruby code.
3. **System C library:** functions imported by Nelua, including allocation and
   POSIX file/process services.
4. **Spinel bootstrap:** the inherited compiler sources remain available to build
   Spinel itself. Its analyzer, native code generator, C AST flattening, and CLI
   objects are not linked into the Kah executable.

This release replaces Kah's authored C implementation. It does not claim to have
ported upstream Spinel, its standard runtime, or Prism to Nelua. Those are
separate upstream dependencies. Supplying a compatible installed Spinel through
`SPINEL_BOOTSTRAP` skips building its compiler from the retained source.

## Reproduce the checks

```sh
make kah-source-audit
make kah-native-test
make kah-test
```

The source audit rejects C/C++ files and inline C escapes under `compiler/` and
checks executable symbols. It requires the Nelua adapter and Prism while refusing
the legacy `sp_parse_file`, `codegen_program`, and `codegen_lua_program` entry points.

The native bridge test covers AST access, embedded NUL bytes, copied results,
independent contexts, and parser diagnostics. The compatibility suite checks 21
Ruby programs against CRuby across standard Lua and LuaJIT, plus local/cyclic
imports, output protection, integer overflow, interpreter arguments and exit
statuses, and copying the compiler away from its source tree with Ruby absent
from PATH.

The tested Nelua revision and Spinel compatibility base are recorded in
`compiler/toolchain.json`. The current platform layer uses POSIX process/file
interfaces. Language coverage is documented in [the Kah guide](kah.md).
